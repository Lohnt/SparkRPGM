import Foundation
import CoreGraphics

/// Every virtual button and the exact `keyCode` RPG Maker listens for.
enum ControlAction: String, CaseIterable, Identifiable {
    case up, down, left, right
    case ok, cancel, shift, control

    var id: String { rawValue }

    /// `KeyboardEvent.key` / `.code` value. RM only consumes `keyCode`, but a
    /// sane key value keeps browser-level handlers (and EasyRPG) happy.
    var key: String {
        switch self {
        case .up: return "ArrowUp"
        case .down: return "ArrowDown"
        case .left: return "ArrowLeft"
        case .right: return "ArrowRight"
        case .ok: return "z"
        case .cancel: return "x"
        case .shift: return "Shift"
        case .control: return "Control"
        }
    }

    var keyCode: Int {
        switch self {
        case .up: return 38
        case .down: return 40
        case .left: return 37
        case .right: return 39
        case .ok: return 90      // Z
        case .cancel: return 88  // X
        case .shift: return 16
        case .control: return 17
        }
    }

    /// Secondary keyCode so games that only listen for Enter/Escape still work.
    var secondaryKeyCode: Int? {
        switch self {
        case .ok: return 13       // Enter
        case .cancel: return 27   // Escape
        default: return nil
        }
    }

    /// `Input._currentState` key used by RPG Maker MV/MZ.
    var rpgmButton: String {
        switch self {
        case .up, .down, .left, .right: return rawValue
        case .ok: return "ok"
        case .cancel: return "cancel"
        case .shift: return "shift"
        case .control: return "control"
        }
    }
}

struct ControlConfig: Codable, Equatable {

    // Normalised (0...1) positions of the two control clusters.
    var dpadX: Double = 0.16
    var dpadY: Double = 0.72
    var actionsX: Double = 0.84
    var actionsY: Double = 0.72

    var dpadScale: Double = 1.0
    var actionScale: Double = 1.0
    var opacity: Double = 0.55

    var autoFade: Bool = true
    var eightWay: Bool = true
    var haptics: Bool = true
    var mirrored: Bool = false
    var showShift: Bool = true
    var showCtrl: Bool = true

    var orientation: OrientationMode = .auto

    static let `default` = ControlConfig()

    var dpadPoint: CGPoint {
        CGPoint(x: mirrored ? 1 - dpadX : dpadX, y: dpadY)
    }

    var actionsPoint: CGPoint {
        CGPoint(x: mirrored ? 1 - actionsX : actionsX, y: actionsY)
    }

    func clamped() -> ControlConfig {
        var copy = self
        copy.dpadX = min(max(copy.dpadX, 0.08), 0.92)
        copy.dpadY = min(max(copy.dpadY, 0.12), 0.92)
        copy.actionsX = min(max(copy.actionsX, 0.08), 0.92)
        copy.actionsY = min(max(copy.actionsY, 0.12), 0.92)
        copy.dpadScale = min(max(copy.dpadScale, 0.6), 1.8)
        copy.actionScale = min(max(copy.actionScale, 0.6), 1.8)
        copy.opacity = min(max(copy.opacity, 0.1), 1.0)
        return copy
    }
}

final class ControlSettingsStore: ObservableObject {

    enum Scope: String {
        case global
        case game
    }

    private static let globalKey = "sparkrpgm.controls.global.v1"
    private static let perGamePrefix = "sparkrpgm.controls.game.v1."

    let gameFolder: String

    @Published var config: ControlConfig {
        didSet { /* persisted explicitly by save(scope:) and by drag-end autosave */ }
    }

    init(gameFolder: String) {
        self.gameFolder = gameFolder
        if let data = UserDefaults.standard.data(forKey: Self.perGamePrefix + gameFolder),
           let decoded = try? JSONDecoder().decode(ControlConfig.self, from: data) {
            config = decoded
        } else if let data = UserDefaults.standard.data(forKey: Self.globalKey),
                  let decoded = try? JSONDecoder().decode(ControlConfig.self, from: data) {
            config = decoded
        } else {
            config = ControlConfig.default
        }
    }

    var hasPerGameOverride: Bool {
        UserDefaults.standard.data(forKey: Self.perGamePrefix + gameFolder) != nil
    }

    func save(scope: Scope) {
        let snapshot = config.clamped()
        config = snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        switch scope {
        case .global:
            UserDefaults.standard.set(data, forKey: Self.globalKey)
        case .game:
            UserDefaults.standard.set(data, forKey: Self.perGamePrefix + gameFolder)
        }
    }

    func reset() {
        config = ControlConfig.default
    }

    func clearPerGameOverride() {
        UserDefaults.standard.removeObject(forKey: Self.perGamePrefix + gameFolder)
    }

    /// Called when the player closes so the last drag is never lost.
    func autosave(scope: Scope) {
        save(scope: scope)
    }
}
