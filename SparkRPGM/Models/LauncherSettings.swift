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

enum LibrarySort: String, Codable, CaseIterable, Identifiable {
    case title
    case recent
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "Name"
        case .recent: return "Recently played"
        case .size: return "Size"
        }
    }
}

struct LauncherSettings: Codable, Equatable {

    var headerTitle: String = "SparkRPGM"
    var accentHex: String = "#7C5CFF"
    var cardSize: CardSize = .standard
    var sort: LibrarySort = .title

    var wallpaperBlur: Double = 12
    var dimOpacity: Double = 0.38
    var glassOpacity: Double = 0.32
    var wallpaperVersion: Int = 0

    /// `nil` = the primary AppIcon.
    var appIconName: String?

    static let `default` = LauncherSettings()

    var accentColor: Color { Color(hex: accentHex) }

    static let accentPresets: [String] = [
        "#7C5CFF", "#4DA3FF", "#39D9A4", "#FFB23E", "#FF5C8A", "#FF6B4A", "#9B5BFF", "#E8E8F0",
    ]
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
