import AVFoundation
import Foundation
import FlutterMacOS

/// Hybrid delegate that supports both file recording AND streaming simultaneously
/// This allows real-time audio processing (e.g., transcription) while saving to file
class RecorderHybridDelegate: NSObject, AudioRecordingDelegate, AVAudioRecorderDelegate {
  var config: RecordConfig?
  
  // File recording (AVAudioRecorder for M4A/AAC/etc file output)
  private var audioRecorder: AVAudioRecorder?
  private var path: String?
  
  // Streaming (AVAudioEngine for real-time PCM audio data)
  private var audioEngine: AVAudioEngine?
  private var amplitude: Float = -160.0
  private let bus = 0
  
  // Callbacks
  private var onPause: () -> ()
  private var onStop: () -> ()
  
  init(onPause: @escaping () -> (), onStop: @escaping () -> ()) {
    self.onPause = onPause
    self.onStop = onStop
  }

  /// Starts hybrid recording: saves to file AND streams audio data
  func start(config: RecordConfig, path: String, recordEventHandler: RecordStreamHandler) throws {
    try deleteFile(path: path)
    
    try initAVAudioSession(config: config)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain)
    
    // 1️⃣ Setup AVAudioRecorder for file output
    let url = URL(fileURLWithPath: path)
    let recorder = try AVAudioRecorder(url: url, settings: getOutputSettings(config: config))
    recorder.delegate = self
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    recorder.record()
    
    audioRecorder = recorder
    self.path = path
    
    // 2️⃣ Setup AVAudioEngine for streaming
    let audioEngine = AVAudioEngine()
    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    
    // Convert to PCM16 for streaming
    let dstFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(config.sampleRate),
      channels: AVAudioChannelCount(config.numChannels),
      interleaved: true
    )
    
    guard let dstFormat = dstFormat else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Format is not supported: \(config.sampleRate)Hz - \(config.numChannels) channels."
      )
    }
    
    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Format conversion is not possible."
      )
    }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    
    audioEngine.inputNode.installTap(
      onBus: bus,
      bufferSize: AVAudioFrameCount(config.streamBufferSize ?? 1024),
      format: srcFormat
    ) { (buffer, _) -> Void in
      self.stream(
        buffer: buffer,
        dstFormat: dstFormat,
        converter: converter,
        recordEventHandler: recordEventHandler
      )
    }
    
    audioEngine.prepare()
    try audioEngine.start()
    
    self.audioEngine = audioEngine
    self.config = config
  }

  func stop(completionHandler: @escaping (String?) -> ()) {
    // Stop file recorder
    audioRecorder?.stop()
    audioRecorder = nil
    
    // Stop audio engine
    if let audioEngine = audioEngine {
      do {
        try setVoiceProcessing(echoCancel: false, autoGain: false)
      } catch {}
      
      audioEngine.inputNode.removeTap(onBus: bus)
      audioEngine.stop()
    }
    audioEngine = nil
    
    let recordedPath = path
    
    completionHandler(recordedPath)
    onStop()
    
    path = nil
    config = nil
  }
  
  func pause() {
    audioRecorder?.pause()
    audioEngine?.pause()
    onPause()
  }
  
  func resume() throws {
    audioRecorder?.record()
    try audioEngine?.start()
  }

  func cancel() throws {
    guard let path = path else { return }
    
    stop { path in }
    
    try deleteFile(path: path)
  }
  
  func getAmplitude() -> Float {
    return amplitude
  }
  
  func dispose() {
    stop { path in }
  }

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    // Audio recording has stopped
  }
  
  // MARK: - Private Helpers
  
  private func updateAmplitude(_ samples: [Int16]) {
    var maxSample: Float = -160.0

    for sample in samples {
      let curSample = abs(Float(sample))
      if (curSample > maxSample) {
        maxSample = curSample
      }
    }
    
    amplitude = 20 * (log(maxSample / 32767.0) / log(10))
  }
  
  // Little endian
  private func convertInt16toUInt8(_ samples: [Int16]) -> [UInt8] {
    var bytes: [UInt8] = []
    
    for sample in samples {
      bytes.append(UInt8(sample & 0x00ff))
      bytes.append(UInt8(sample >> 8 & 0x00ff))
    }
    
    return bytes
  }
  
  private func stream(
    buffer: AVAudioPCMBuffer,
    dstFormat: AVAudioFormat,
    converter: AVAudioConverter,
    recordEventHandler: RecordStreamHandler
  ) -> Void {
    let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    
    // Determine frame capacity
    let capacity = (UInt32(dstFormat.sampleRate) * dstFormat.channelCount * buffer.frameLength) / (UInt32(buffer.format.sampleRate) * buffer.format.channelCount)
    
    // Destination buffer
    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
      print("Unable to create output buffer")
      stop { path in }
      return
    }
    
    // Convert input buffer (resample, num channels)
    var error: NSError? = nil
    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
    if error != nil {
      return
    }
    
    if let channelData = convertedBuffer.int16ChannelData {
      // Fill samples
      let channelDataPointer = channelData.pointee
      let samples = stride(from: 0,
                           to: Int(convertedBuffer.frameLength),
                           by: buffer.stride).map{ channelDataPointer[$0] }

      // Update current amplitude
      updateAmplitude(samples)

      // Send bytes to Flutter stream
      if let eventSink = recordEventHandler.eventSink {
        let bytes = Data(_: convertInt16toUInt8(samples))
        
        DispatchQueue.main.async {
          eventSink(FlutterStandardTypedData(bytes: bytes))
        }
      }
    }
  }
  
  // Set up AGC & echo cancel
  private func setVoiceProcessing(echoCancel: Bool, autoGain: Bool) throws {
    guard let audioEngine = audioEngine else { return }
    
    if #available(macOS 10.15, *) {
      do {
        try audioEngine.inputNode.setVoiceProcessingEnabled(echoCancel)
        audioEngine.inputNode.isVoiceProcessingAGCEnabled = autoGain
      } catch {
        throw RecorderError.error(
          message: "Failed to setup voice processing",
          details: "Echo cancel error: \(error)"
        )
      }
    }
  }
  
  private func deleteFile(path: String) throws {
    do {
      let fileManager = FileManager.default
      
      if fileManager.fileExists(atPath: path) {
        try fileManager.removeItem(atPath: path)
      }
    } catch {
      throw RecorderError.error(message: "Failed to delete previous recording", details: error.localizedDescription)
    }
  }
}

