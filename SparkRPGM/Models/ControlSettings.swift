import Foundation
import CoreGraphics

/// Every virtual button available in the RPG Maker key library.
enum VirtualButtonID: String, CaseIterable, Identifiable, Codable {
    case z = "Z"
    case x = "X"
    case shift = "SHIFT"
    case esc = "ESC"
    case ctrl = "CTRL"
    case enter = "ENTER"
    case space = "SPACE"
    case q = "Q"
    case w = "W"
    case a = "A"
    case s = "S"
    case d = "D"
    case tab = "TAB"
    case f2 = "F2"
    case f8 = "F8"

    var id: String { rawValue }

    var label: String { rawValue }

    var action: ControlAction {
        switch self {
        case .z: return .ok
        case .x: return .cancel
        case .shift: return .shift
        case .esc: return .escape
        case .ctrl: return .control
        case .enter: return .enter
        case .space: return .space
        case .q: return .q
        case .w: return .w
        case .a: return .a
        case .s: return .s
        case .d: return .d
        case .tab: return .tab
        case .f2: return .f2
        case .f8: return .f8
        }
    }

    var isPill: Bool {
        self == .shift || self == .esc || self == .ctrl || self == .tab || self == .space
    }

    var isPrimary: Bool {
        self == .z
    }
}

/// Every virtual button and the exact `keyCode` RPG Maker listens for.
enum ControlAction: String, CaseIterable, Identifiable {
    case up, down, left, right
    case ok, cancel, shift, control, escape
    case enter, space, q, w, a, s, d, tab, f2, f8

    var id: String { rawValue }

    /// `KeyboardEvent.key` value.
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
        case .escape: return "Escape"
        case .enter: return "Enter"
        case .space: return " "
        case .q: return "q"
        case .w: return "w"
        case .a: return "a"
        case .s: return "s"
        case .d: return "d"
        case .tab: return "Tab"
        case .f2: return "F2"
        case .f8: return "F8"
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
        case .escape: return 27  // Escape / menu
        case .enter: return 13
        case .space: return 32
        case .q: return 81
        case .w: return 87
        case .a: return 65
        case .s: return 83
        case .d: return 68
        case .tab: return 9
        case .f2: return 113
        case .f8: return 119
        }
    }

    /// Secondary keyCode so games that only listen for Enter still confirm on Z.
    var secondaryKeyCode: Int? {
        switch self {
        case .ok: return 13       // Enter
        default: return nil
        }
    }

    /// `Input._currentState` key used by RPG Maker MV/MZ.
    var rpgmButton: String {
        switch self {
        case .up, .down, .left, .right: return rawValue
        case .ok, .enter, .space: return "ok"
        case .cancel: return "cancel"
        case .escape: return "escape"
        case .shift: return "shift"
        case .control: return "control"
        case .q: return "pageup"
        case .w: return "pagedown"
        default: return rawValue
        }
    }
}

/// State and normalized position for an individual virtual button.
struct CustomButtonState: Codable, Equatable {
    var isEnabled: Bool
    var x: Double
    var y: Double
}

struct ControlConfig: Codable, Equatable {

    // Normalised (0...1) position of the continuous sculpted D-Pad.
    var dpadX: Double = 0.16
    var dpadY: Double = 0.74
    var dpadScale: Double = 1.0

    // Master button scaling and opacity
    var buttonScale: Double = 1.0
    var opacity: Double = 0.55

    var autoFade: Bool = false
    var eightWay: Bool = true
    var haptics: Bool = true
    var mirrored: Bool = false
    var hideAllControls: Bool = false

    var orientation: OrientationMode = .auto

    // Custom button states per VirtualButtonID
    var buttons: [String: CustomButtonState] = ControlConfig.defaultButtons

    static var defaultButtons: [String: CustomButtonState] {
        var map: [String: CustomButtonState] = [:]
        // 4 essential buttons enabled by default:
        // Z: primary lower-right thumb position
        map[VirtualButtonID.z.rawValue] = CustomButtonState(isEnabled: true, x: 0.88, y: 0.78)
        // X: diagonal upper-left from Z
        map[VirtualButtonID.x.rawValue] = CustomButtonState(isEnabled: true, x: 0.77, y: 0.72)
        // SHIFT: compact pill above Z/X
        map[VirtualButtonID.shift.rawValue] = CustomButtonState(isEnabled: true, x: 0.76, y: 0.56)
        // ESC: compact pill beside SHIFT
        map[VirtualButtonID.esc.rawValue] = CustomButtonState(isEnabled: true, x: 0.88, y: 0.56)

        // Library of other buttons (disabled by default, with ergonomic initial placements):
        map[VirtualButtonID.ctrl.rawValue] = CustomButtonState(isEnabled: false, x: 0.65, y: 0.56)
        map[VirtualButtonID.enter.rawValue] = CustomButtonState(isEnabled: false, x: 0.88, y: 0.90)
        map[VirtualButtonID.space.rawValue] = CustomButtonState(isEnabled: false, x: 0.77, y: 0.86)
        map[VirtualButtonID.q.rawValue] = CustomButtonState(isEnabled: false, x: 0.08, y: 0.44)
        map[VirtualButtonID.w.rawValue] = CustomButtonState(isEnabled: false, x: 0.24, y: 0.44)
        map[VirtualButtonID.a.rawValue] = CustomButtonState(isEnabled: false, x: 0.65, y: 0.72)
        map[VirtualButtonID.s.rawValue] = CustomButtonState(isEnabled: false, x: 0.65, y: 0.84)
        map[VirtualButtonID.d.rawValue] = CustomButtonState(isEnabled: false, x: 0.54, y: 0.84)
        map[VirtualButtonID.tab.rawValue] = CustomButtonState(isEnabled: false, x: 0.08, y: 0.32)
        map[VirtualButtonID.f2.rawValue] = CustomButtonState(isEnabled: false, x: 0.38, y: 0.12)
        map[VirtualButtonID.f8.rawValue] = CustomButtonState(isEnabled: false, x: 0.62, y: 0.12)
        return map
    }

    static let `default` = ControlConfig()

    func isEnabled(_ id: VirtualButtonID) -> Bool {
        buttons[id.rawValue]?.isEnabled ?? false
    }

    func position(for id: VirtualButtonID) -> CGPoint {
        if let state = buttons[id.rawValue] {
            return CGPoint(x: mirrored ? 1.0 - state.x : state.x, y: state.y)
        }
        let fallback = Self.defaultButtons[id.rawValue] ?? CustomButtonState(isEnabled: false, x: 0.8, y: 0.8)
        return CGPoint(x: mirrored ? 1.0 - fallback.x : fallback.x, y: fallback.y)
    }

    mutating func setEnabled(_ id: VirtualButtonID, _ enabled: Bool) {
        if var state = buttons[id.rawValue] {
            state.isEnabled = enabled
            buttons[id.rawValue] = state
        } else {
            var state = Self.defaultButtons[id.rawValue] ?? CustomButtonState(isEnabled: false, x: 0.8, y: 0.8)
            state.isEnabled = enabled
            buttons[id.rawValue] = state
        }
    }

    mutating func setPosition(for id: VirtualButtonID, x: Double, y: Double) {
        let actualX = mirrored ? 1.0 - x : x
        if var state = buttons[id.rawValue] {
            state.x = min(max(actualX, 0.04), 0.96)
            state.y = min(max(y, 0.06), 0.94)
            buttons[id.rawValue] = state
        } else {
            var state = Self.defaultButtons[id.rawValue] ?? CustomButtonState(isEnabled: true, x: actualX, y: y)
            state.x = min(max(actualX, 0.04), 0.96)
            state.y = min(max(y, 0.06), 0.94)
            buttons[id.rawValue] = state
        }
    }

    var dpadPoint: CGPoint {
        CGPoint(x: mirrored ? 1.0 - dpadX : dpadX, y: dpadY)
    }

    func clamped() -> ControlConfig {
        var copy = self
        copy.dpadX = min(max(copy.dpadX, 0.06), 0.94)
        copy.dpadY = min(max(copy.dpadY, 0.08), 0.92)
        copy.dpadScale = min(max(copy.dpadScale, 0.6), 1.8)
        copy.buttonScale = min(max(copy.buttonScale, 0.6), 1.8)
        copy.opacity = min(max(copy.opacity, 0.15), 1.0)
        return copy
    }
}

final class ControlSettingsStore: ObservableObject {

    enum Scope: String {
        case global
        case game
    }

    private static let globalKey = "sparkrpgm.controls.global.v2"
    private static let perGamePrefix = "sparkrpgm.controls.game.v2."

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
