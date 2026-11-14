import UIKit

/// iOS 15 safe orientation locking.
///
/// The app is built with `UIRequiresFullScreen`, so changing the mask returned
/// from `application(_:supportedInterfaceOrientationsFor:)` plus the legacy
/// `UIDevice` orientation value is enough to force a rotation. (iOS 16 moved to
/// `requestGeometryUpdate`, which SparkRPGM deliberately does not use.)
enum OrientationMode: String, CaseIterable, Identifiable, Codable {
    case landscape
    case portrait
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        case .auto: return "Auto"
        }
    }

    var symbolName: String {
        switch self {
        case .landscape: return "rectangle"
        case .portrait: return "rectangle.portrait"
        case .auto: return "arrow.triangle.2.circlepath"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .landscape: return .landscape
        case .portrait: return .portrait
        case .auto: return .allButUpsideDown
        }
    }
}

final class OrientationManager {

    static let shared = OrientationManager()

    private(set) var mode: OrientationMode = .auto

    /// Read by `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`.
    var supportedMask: UIInterfaceOrientationMask {
        mode.mask
    }

    private init() {}

    func apply(_ newMode: OrientationMode) {
        mode = newMode
        guard newMode != .auto else {
            rotate(to: nil)
            return
        }

        let target: UIInterfaceOrientation
        switch newMode {
        case .landscape:
            target = preferredLandscapeOrientation()
        case .portrait:
            target = .portrait
        case .auto:
            return
        }
        rotate(to: target)
    }

    func restoreAuto() {
        mode = .auto
        rotate(to: nil)
    }

    private func preferredLandscapeOrientation() -> UIInterfaceOrientation {
        // Match the device's current handedness when possible so the game does
        // not appear upside down after locking.
        if let scene = activeWindowScene() {
            switch scene.interfaceOrientation {
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: break
            }
        }
        return .landscapeRight
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    private func rotate(to orientation: UIInterfaceOrientation?) {
        DispatchQueue.main.async {
            if let orientation = orientation {
                UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            }
            UIViewController.attemptRotationToDeviceOrientation()
            self.activeWindowScene()?.windows.forEach { $0.rootViewController?.setNeedsStatusBarAppearanceUpdate() }
        }
    }
}
