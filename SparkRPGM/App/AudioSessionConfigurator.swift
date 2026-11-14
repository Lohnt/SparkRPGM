import AVFoundation
import Foundation

/// Keeps the shared audio session in `.playback` (`.mixWithOthers`) so the
/// iPad's Silent switch never mutes RPG Maker BGM or video audio.
enum AudioSessionConfigurator {

    private static var observersInstalled = false

    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            Log.error("Audio session activation failed", error: error)
        }
        installObserversIfNeeded()
    }

    static func handleInterruption(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let reason = AVAudioSession.InterruptionType(rawValue: reasonValue) else { return }

        switch reason {
        case .began:
            break
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                reactivate()
            }
        @unknown default:
            break
        }
    }

    static func reactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            Log.error("Audio session re-activation failed", error: error)
        }
    }

    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            handleInterruption(notification)
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
                reactivate()
            }
        }
    }
}
