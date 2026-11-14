import SwiftUI

/// Every engine SparkRPGM knows how to launch.
///
/// The raw values are what appears inside the library's engine badge, so they
/// are intentionally short.
enum GameEngine: String, Codable, CaseIterable, Identifiable {

    case rpgMakerMZ = "MZ"
    case rpgMakerMV = "MV"
    case rpgMaker2000 = "2000"
    case rpgMaker2003 = "2003"
    case rpgMakerXP = "XP"
    case rpgMakerVX = "VX"
    case rpgMakerVXAce = "VXAce"
    case web = "Web"
    case unknown = "?"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rpgMakerMZ: return "RPG Maker MZ"
        case .rpgMakerMV: return "RPG Maker MV"
        case .rpgMaker2000: return "RPG Maker 2000"
        case .rpgMaker2003: return "RPG Maker 2003"
        case .rpgMakerXP: return "RPG Maker XP"
        case .rpgMakerVX: return "RPG Maker VX"
        case .rpgMakerVXAce: return "RPG Maker VX Ace"
        case .web: return "HTML5 / Web"
        case .unknown: return "Unknown"
        }
    }

    /// MZ / MV / plain HTML5 run inside the WKWebView runtime.
    var isWebBased: Bool {
        switch self {
        case .rpgMakerMZ, .rpgMakerMV, .web: return true
        default: return false
        }
    }

    /// EasyRPG Player (WebAssembly) handles the 2000/2003 LCF engines.
    var isEasyRPG: Bool {
        self == .rpgMaker2000 || self == .rpgMaker2003
    }

    /// XP / VX / VX Ace are offered through the optional mkxp wrapper.
    var isMKXP: Bool {
        self == .rpgMakerXP || self == .rpgMakerVX || self == .rpgMakerVXAce
    }

    /// Engines whose save files live in `Documents/save/<game>`.
    var usesNativeSaveFolder: Bool {
        true
    }

    var saveFileExtension: String {
        switch self {
        case .rpgMakerMZ: return "rmmzsave"
        case .rpgMakerMV: return "rpgsave"
        case .rpgMaker2000, .rpgMaker2003: return "lsd"
        case .rpgMakerXP: return "rxdata"
        case .rpgMakerVX: return "rvdata"
        case .rpgMakerVXAce: return "rvdata2"
        case .web, .unknown: return "save"
        }
    }

    var badgeColor: Color {
        switch self {
        case .rpgMakerMZ: return Color(red: 0.17, green: 0.78, blue: 0.62)
        case .rpgMakerMV: return Color(red: 0.23, green: 0.66, blue: 1.00)
        case .rpgMaker2000: return Color(red: 1.00, green: 0.72, blue: 0.28)
        case .rpgMaker2003: return Color(red: 1.00, green: 0.56, blue: 0.35)
        case .rpgMakerXP: return Color(red: 0.72, green: 0.47, blue: 1.00)
        case .rpgMakerVX: return Color(red: 0.96, green: 0.40, blue: 0.62)
        case .rpgMakerVXAce: return Color(red: 0.90, green: 0.30, blue: 0.47)
        case .web: return Color(red: 0.55, green: 0.60, blue: 0.72)
        case .unknown: return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }

    /// Human readable runtime hint shown in the game card's context menu.
    var runtimeDescription: String {
        switch self {
        case .rpgMakerMZ, .rpgMakerMV, .web: return "WKWebView + byte-range scheme handler"
        case .rpgMaker2000, .rpgMaker2003: return "EasyRPG Player (WebAssembly)"
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce: return "mkxp (when bundled)"
        case .unknown: return "Unrecognised engine"
        }
    }
}
