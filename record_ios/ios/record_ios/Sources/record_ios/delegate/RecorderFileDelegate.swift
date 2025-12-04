import AVFoundation
import Foundation
import UIKit

class RecorderFileDelegate: NSObject, AudioRecordingFileDelegate, AVAudioRecorderDelegate {
  var config: RecordConfig?
  
  private var audioRecorder: AVAudioRecorder?
  private var path: String?
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
      selector: #selector(handleAppWillTerminate),
      name: UIApplication.willTerminateNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }
  
  @objc private func handleAppWillTerminate() {
    if audioRecorder?.isRecording == true {
      audioRecorder?.stop()
      audioRecorder = nil
      
      if path != nil {
        if manageAudioSession {
          try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }        
        onStop()
      }
      
      path = nil
      config = nil
    }
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
              self.resume()
              
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

  func start(config: RecordConfig, path: String) throws {
    try deleteFile(path: path)

    try initAVAudioSession(config: config, manageAudioSession: manageAudioSession)

    let url = URL(fileURLWithPath: path)

    let recorder = try AVAudioRecorder(url: url, settings: getOutputSettings(config: config))

    recorder.delegate = self
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    
    recorder.record()
    
    audioRecorder = recorder
    self.path = path
    self.config = config
  }

  func stop(completionHandler: @escaping (String?) -> ()) {
    audioRecorder?.stop()
    audioRecorder = nil

    completionHandler(path)
    onStop()
    
    path = nil
    config = nil
  }
  
  func pause() {
    guard let recorder = audioRecorder, recorder.isRecording else {
      return
    }
    
    recorder.pause()
    onPause()
  }
  
  func resume() {
    audioRecorder?.record()
  }

  func cancel() throws {
    guard let path = path else { return }
    
    stop { path in }
    
    try deleteFile(path: path)
  }
  
  func getAmplitude() -> Float {
    audioRecorder?.updateMeters()
    return audioRecorder?.averagePower(forChannel: 0) ?? -160
  }
  
  func dispose() {
    stop { path in }
  }

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
      // Audio recording has stopped
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
