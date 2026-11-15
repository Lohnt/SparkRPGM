import Foundation
import ImageIO

/// Finds the best built-in artwork for a game and caches it so the Prism Icons
/// grid can show a real image even when the user never picked a cover.
///
/// Priority follows how explicit the asset is:
/// exported title art (`titles1`, `titles2`, `Title/`) -> high-resolution APK
/// launcher icons (>= 128px) -> the tiny `icon/icon.png` plugin icon.
///
/// Everything is resolved case-insensitively because games are authored on
/// Windows and macOS. Small icons are still returned, but `CoverImageView`
/// renders anything under 96px at a crisp 48pt instead of stretching it.
enum GameCoverFinder {

    /// Exporters write the title screen here. `titles1` is the main artwork.
    private static let titleFolders = [
        "img/titles1",
        "www/img/titles1",
        "img/titles2",
        "www/img/titles2",
        "Title",
        "www/Title",
    ]

    /// Android launcher icons, only when actually high resolution.
    private static let launcherCandidates = [
        "res/mipmap-xxxhdpi/ic_launcher.png",
        "res/mipmap-xxhdpi/ic_launcher.png",
        "assets/res/mipmap-xxxhdpi/ic_launcher.png",
        "assets/res/mipmap-xxhdpi/ic_launcher.png",
        "res/mipmap-xhdpi/ic_launcher.png",
        "assets/res/mipmap-xhdpi/ic_launcher.png",
        "res/drawable-xxxhdpi/icon.png",
        "res/drawable-xxhdpi/icon.png",
        "assets/res/drawable-xxxhdpi/icon.png",
        "assets/res/drawable-xxhdpi/icon.png",
    ]

    /// Last resort: the plugin icon. Kept even when it is only 32×32 because a
    /// recognisable mark beats a blank card.
    private static let iconFallbacks = [
        "icon/icon.png",
        "icon/icon.jpg",
        "www/icon/icon.png",
        "www/icon/icon.jpg",
        "icon.png",
        "www/icon.png",
    ]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    static let minimumLauncherPixels = 128
    static let minimumFullBleedPixels = 96

    /// Searches the game folder and the promoted engine root (they differ for
    /// manually copied `www/` wrappers) and returns the first usable image.
    static func find(inGameRoot gameRoot: URL, engineRoot: URL) -> URL? {
        let gameResolver = CaseInsensitiveFileResolver(root: gameRoot)
        let engineResolver = CaseInsensitiveFileResolver(root: engineRoot)
        let resolvers = [engineResolver, gameResolver]

        // 1. Full-resolution title artwork.
        for resolver in resolvers {
            for folder in titleFolders {
                if let url = firstImage(in: folder, resolver: resolver),
                   isLargeEnough(url, minimum: minimumFullBleedPixels) {
                    return url
                }
            }
        }

        // 2. High-resolution Android launcher art.
        for resolver in resolvers {
            for path in launcherCandidates {
                guard let url = resolver.resolve(path), isUsableImage(url) else { continue }
                if isLargeEnough(url, minimum: minimumLauncherPixels) {
                    return url
                }
            }
        }

        // 3. The plugin icon, whatever its size.
        for resolver in resolvers {
            for path in iconFallbacks {
                if let url = resolver.resolve(path), isUsableImage(url) {
                    return url
                }
            }
        }

        return nil
    }

    /// Copies the candidate into `.spark/auto-covers/<game>.<ext>`.
    @discardableResult
    static func cache(candidate: URL, forGame name: String) -> URL? {
        let fileManager = FileManager.default
        let fileExtension = candidate.pathExtension.lowercased().isEmpty
            ? "png"
            : candidate.pathExtension.lowercased()
        let target = AppPaths.autoCoverFile(forGame: name, fileExtension: fileExtension)

        do {
            try fileManager.createDirectory(at: AppPaths.autoCovers, withIntermediateDirectories: true, attributes: nil)
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: candidate, to: target)
            return target
        } catch {
            Log.error("Auto cover cache failed for \(name)", error: error)
            return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Removes a cached cover after a delete or rename.
    static func clear(forGame name: String) {
        let fileManager = FileManager.default
        for fileExtension in ["png", "jpg", "jpeg", "webp"] {
            let url = AppPaths.autoCoverFile(forGame: name, fileExtension: fileExtension)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Moves the cached cover when a game is renamed.
    static func move(from oldName: String, to newName: String) {
        let fileManager = FileManager.default
        guard let source = AppPaths.autoCoverURL(forGame: oldName) else { return }
        let target = AppPaths.autoCoverFile(forGame: newName, fileExtension: source.pathExtension)
        try? fileManager.createDirectory(at: AppPaths.autoCovers, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.removeItem(at: target)
        }
        try? fileManager.moveItem(at: source, to: target)
    }

    // MARK: - Helpers

    private static func firstImage(in folder: String, resolver: CaseInsensitiveFileResolver) -> URL? {
        guard let directory = resolver.resolve(folder), AppPaths.isDirectory(directory) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }

        let sorted = names
            .filter { !$0.hasPrefix(".") }
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let left = lhs.lowercased()
                let right = rhs.lowercased()
                let leftRank = rank(for: left)
                let rightRank = rank(for: right)
                if leftRank != rightRank { return leftRank < rightRank }
                return left < right
            }

        for name in sorted {
            let url = directory.appendingPathComponent(name)
            if isUsableImage(url) { return url }
        }
        return nil
    }

    private static func rank(for name: String) -> Int {
        if name.hasSuffix(".png") { return 0 }
        if name.hasSuffix(".jpg") { return 1 }
        if name.hasSuffix(".jpeg") { return 2 }
        return 3
    }

    private static func isUsableImage(_ url: URL) -> Bool {
        guard AppPaths.isDirectory(url) == false else { return false }
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) > 0
    }

    /// Reads the real pixel dimensions without decoding the image into memory.
    private static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// Unknown dimensions count as large enough: a readable file is better than
    /// falling through to the plugin icon.
    private static func isLargeEnough(_ url: URL, minimum: Int) -> Bool {
        guard let size = pixelSize(of: url) else { return true }
        return max(size.width, size.height) >= minimum
    }
}
