import SwiftUI
import UIKit

enum CardSize: String, Codable, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var minimumWidth: CGFloat {
        switch self {
        case .compact: return 128
        case .standard: return 186
        case .large: return 276
        }
    }

    var coverAspect: CGFloat {
        switch self {
        case .compact: return 0.86
        case .standard: return 0.72
        case .large: return 0.66
        }
    }
}

/// Two launcher personalities:
/// - `sparkLines`: a dense, text-first list (Spark / Ren'Py style, no covers).
/// - `prismIcons`: a multi-column cover grid (Prism Launcher style).
enum LibraryViewStyle: String, Codable, CaseIterable, Identifiable {
    case sparkLines
    case prismIcons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sparkLines: return "Spark Lines"
        case .prismIcons: return "Prism Icons"
        }
    }

    var subtitle: String {
        switch self {
        case .sparkLines: return "A fast text-first list — no cover art"
        case .prismIcons: return "A cover grid with large artwork"
        }
    }

    var symbolName: String {
        switch self {
        case .sparkLines: return "list.bullet.rectangle"
        case .prismIcons: return "square.grid.2x2.fill"
        }
    }

    var toggled: LibraryViewStyle {
        self == .sparkLines ? .prismIcons : .sparkLines
    }
}

enum LibrarySort: String, Codable, CaseIterable, Identifiable {
    case title
    case recent
    case mostPlayed
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "Name"
        case .recent: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .size: return "Size"
        }
    }

    var symbolName: String {
        switch self {
        case .title: return "textformat.abc"
        case .recent: return "clock"
        case .mostPlayed: return "flame"
        case .size: return "internaldrive"
        }
    }
}

struct LauncherSettings: Codable, Equatable {

    var headerTitle: String = "SparkRPGM"
    var accentHex: String = "#7C5CFF"
    var cardSize: CardSize = .standard
    var sort: LibrarySort = .title
    var viewStyle: LibraryViewStyle = .prismIcons

    /// Colour of the 4pt bar on the left edge of every `Spark Lines` row.
    /// Ignored when `accentLineAutoByEngine` is on or a game overrides it.
    var accentLineHex: String = "#7C5CFF"
    var accentLineAutoByEngine: Bool = false

    var wallpaperBlur: Double = 12
    var dimOpacity: Double = 0.38
    var glassOpacity: Double = 0.32
    var wallpaperVersion: Int = 0

    /// `nil` = the primary AppIcon.
    var appIconName: String?

    enum CodingKeys: String, CodingKey {
        case headerTitle
        case accentHex
        case cardSize
        case sort
        case viewStyle
        case accentLineHex
        case accentLineAutoByEngine
        case wallpaperBlur
        case dimOpacity
        case glassOpacity
        case wallpaperVersion
        case appIconName
    }

    static let `default` = LauncherSettings()

    var accentColor: Color { Color(hex: accentHex) }
    var accentLineColor: Color { Color(hex: accentLineHex) }

    /// Resolution order: per-game override → auto-by-engine → launcher line colour.
    func lineColor(for game: Game) -> Color {
        if let hex = game.lineColorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        if accentLineAutoByEngine {
            return game.engine.badgeColor
        }
        return accentLineColor
    }

    static let accentPresets: [String] = [
        "#7C5CFF", "#4DA3FF", "#39D9A4", "#FFB23E", "#FF5C8A", "#FF6B4A", "#9B5BFF", "#E8E8F0",
    ]

    static let linePresets: [String] = [
        "#7C5CFF", "#4DA3FF", "#39D9A4", "#FFB23E", "#FF5C8A", "#FF6B4A", "#9B5BFF",
        "#39C5FF", "#F2E14C", "#E8E8F0", "#6E7385", "#FF3B30",
    ]
}

extension LauncherSettings {

    /// Hand-written so older persisted settings keep working after new
    /// properties are added (the synthesized decoder throws on missing keys).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LauncherSettings.default

        headerTitle = try container.decodeIfPresent(String.self, forKey: .headerTitle) ?? fallback.headerTitle
        accentHex = try container.decodeIfPresent(String.self, forKey: .accentHex) ?? fallback.accentHex
        cardSize = try container.decodeIfPresent(CardSize.self, forKey: .cardSize) ?? fallback.cardSize
        sort = try container.decodeIfPresent(LibrarySort.self, forKey: .sort) ?? fallback.sort
        viewStyle = try container.decodeIfPresent(LibraryViewStyle.self, forKey: .viewStyle) ?? fallback.viewStyle

        accentLineHex = try container.decodeIfPresent(String.self, forKey: .accentLineHex) ?? fallback.accentLineHex
        accentLineAutoByEngine = try container.decodeIfPresent(Bool.self, forKey: .accentLineAutoByEngine)
            ?? fallback.accentLineAutoByEngine

        wallpaperBlur = try container.decodeIfPresent(Double.self, forKey: .wallpaperBlur) ?? fallback.wallpaperBlur
        dimOpacity = try container.decodeIfPresent(Double.self, forKey: .dimOpacity) ?? fallback.dimOpacity
        glassOpacity = try container.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? fallback.glassOpacity
        wallpaperVersion = try container.decodeIfPresent(Int.self, forKey: .wallpaperVersion) ?? fallback.wallpaperVersion
        appIconName = try container.decodeIfPresent(String.self, forKey: .appIconName)
    }
}

final class LauncherSettingsStore: ObservableObject {

    private static let storageKey = "sparkrpgm.launcher.settings.v1"

    @Published var settings: LauncherSettings {
        didSet { scheduleSave() }
    }

    private var saveWorkItem: DispatchWorkItem?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(LauncherSettings.self, from: data) {
            settings = decoded
        } else {
            settings = LauncherSettings.default
        }
    }

    func resetAppearance() {
        var updated = settings
        updated.wallpaperBlur = LauncherSettings.default.wallpaperBlur
        updated.dimOpacity = LauncherSettings.default.dimOpacity
        updated.glassOpacity = LauncherSettings.default.glassOpacity
        updated.accentHex = LauncherSettings.default.accentHex
        updated.accentLineHex = LauncherSettings.default.accentLineHex
        updated.accentLineAutoByEngine = LauncherSettings.default.accentLineAutoByEngine
        updated.wallpaperVersion += 1
        settings = updated
    }

    func bumpWallpaper() {
        var updated = settings
        updated.wallpaperVersion += 1
        settings = updated
    }

    func setWallpaper(_ image: UIImage) -> Bool {
        guard let data = ImageTools.jpegData(from: image, maxPixel: 2400, quality: 0.9) else { return false }
        do {
            try FileManager.default.createDirectory(at: AppPaths.theme, withIntermediateDirectories: true, attributes: nil)
            try data.write(to: AppPaths.wallpaper, options: .atomic)
            bumpWallpaper()
            return true
        } catch {
            Log.error("Wallpaper write failed", error: error)
            return false
        }
    }

    func removeWallpaper() {
        try? FileManager.default.removeItem(at: AppPaths.wallpaper)
        bumpWallpaper()
    }

    var wallpaperExists: Bool {
        FileManager.default.fileExists(atPath: AppPaths.wallpaper.path)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = settings
        let item = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}

// MARK: - Colour helpers

extension Color {

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red, green, blue, alpha: Double
        switch cleaned.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        default:
            red = 1
            green = 1
            blue = 1
            alpha = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var hexString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#7C5CFF"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}
