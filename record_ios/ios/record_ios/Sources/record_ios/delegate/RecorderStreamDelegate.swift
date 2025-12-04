import AVFoundation
import Foundation
import Flutter

class RecorderStreamDelegate: NSObject, AudioRecordingStreamDelegate {
  var config: RecordConfig?
  
  private var audioEngine: AVAudioEngine?
  private var amplitude: Float = -160.0
  private let bus = 0
  private var onPause: () -> ()
  var onResume: (() -> ())?
  private var onStop: () -> ()
  private let manageAudioSession: Bool
  
  init(manageAudioSession: Bool, onPause: @escaping () -> (), onResume: @escaping () -> (), onStop: @escaping () -> ()) {
    self.manageAudioSession = manageAudioSession
    self.onPause = onPause
    self.onResume = onResume
    self.onStop = onStop
    super.init()
    setupNotifications()
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }
  
  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }
    
    guard let config = self.config else {
      return
    }
  
    if type == AVAudioSession.InterruptionType.began {
      // Interruption began (e.g., phone call started)
      if config.audioInterruption != AudioInterruptionMode.none {
        pause()
      }
    } else if type == AVAudioSession.InterruptionType.ended {
      // Interruption ended (e.g., phone call ended)
      if config.audioInterruption == AudioInterruptionMode.pauseResume {
        guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
          return
        }
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

        if options.contains(.shouldResume) {
          // Add delay for phone calls and other interruptions to allow iOS to properly reconfigure audio
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            
            // Verify we still have config (recording hasn't been stopped)
            guard self.config != nil else { return }
            
            do {
              // Reconfigure audio session before resuming
              let session = AVAudioSession.sharedInstance()
              try session.setCategory(.playAndRecord, options: AVAudioSession.CategoryOptions(config.iosConfig.categoryOptions))
              try session.setActive(true, options: .notifyOthersOnDeactivation)
              
              // Resume recording
              try self.resume()
              
              // Notify Flutter that recording has resumed
              DispatchQueue.main.async {
                self.onResume?()
              }
            } catch {
              // Failed to resume - stop recording
              self.stop { path in }
            }
          }
        } else {
          // System says we shouldn't resume - stop recording
          stop { path in }
        }
      }
    }
  }

  func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
    let audioEngine = AVAudioEngine()

    try initAVAudioSession(config: config, manageAudioSession: manageAudioSession)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)
    
    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)
    
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
      format: srcFormat) { (buffer, _) -> Void in

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
    if let audioEngine = audioEngine {
      do {
        try setVoiceProcessing(echoCancel: false, autoGain: false, audioEngine: audioEngine)
      } catch {}
    }
    
    audioEngine?.inputNode.removeTap(onBus: bus)
    audioEngine?.stop()
    audioEngine = nil
    
    completionHandler(nil)
    onStop()
    
    config = nil
  }
  
  func pause() {
    audioEngine?.pause()
    onPause()
  }
  
  func resume() throws {
    audioEngine?.prepare()
    try audioEngine?.start()
  }
  
  func cancel() throws {
    stop { path in }
  }
  
  func getAmplitude() -> Float {
    return amplitude
  }
  
  private func updateAmplitude(_ samples: [Int16]) {
    var maxSample:Float = -160.0

    for sample in samples {
      let curSample = abs(Float(sample))
      if (curSample > maxSample) {
        maxSample = curSample
      }
    }
    
    amplitude = 20 * (log(maxSample / 32767.0) / log(10))
  }
  
  func dispose() {
    stop { path in }
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

      // Send bytes
      if let eventSink = recordEventHandler.eventSink {
        let bytes = Data(_: convertInt16toUInt8(samples))
        
        DispatchQueue.main.async {
          eventSink(FlutterStandardTypedData(bytes: bytes))
        }
      }
    }
  }
  
  // Set up AGC & echo cancel
  private func setVoiceProcessing(echoCancel: Bool, autoGain: Bool, audioEngine: AVAudioEngine) throws {
    if #available(iOS 13.0, *) {
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
}
