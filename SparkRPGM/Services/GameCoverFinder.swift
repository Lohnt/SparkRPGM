import Foundation

/// Finds the best built-in artwork for a game and caches it so the Prism Icons
/// grid can show a real image even when the user never picked a cover.
///
/// Priority follows how explicit the asset is:
/// `icon/icon.png` -> MZ/MV title art -> RPG Maker 2000/2003 `Title/` -> APK
/// launcher icons. Everything is resolved case-insensitively because games are
/// authored on Windows and macOS.
enum GameCoverFinder {

    private static let directCandidates = [
        "icon/icon.png",
        "icon/icon.jpg",
        "icon.png",
        "www/icon/icon.png",
        "www/icon/icon.jpg",
        "www/icon.png",
        "res/mipmap-xxxhdpi/ic_launcher.png",
        "res/mipmap-xxhdpi/ic_launcher.png",
        "res/drawable-xxxhdpi/icon.png",
        "assets/res/mipmap-xxxhdpi/ic_launcher.png",
        "assets/res/drawable-xxxhdpi/icon.png",
    ]

    private static let titleFolders = [
        "img/titles1",
        "www/img/titles1",
        "Title",
        "www/Title",
    ]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    /// Searches the game folder and the promoted engine root (they differ for
    /// manually copied `www/` wrappers) and returns the first usable image.
    static func find(inGameRoot gameRoot: URL, engineRoot: URL) -> URL? {
        let gameResolver = CaseInsensitiveFileResolver(root: gameRoot)
        let engineResolver = CaseInsensitiveFileResolver(root: engineRoot)
        let resolvers = [engineResolver, gameResolver]

        for resolver in resolvers {
            for path in directCandidates {
                if let url = resolver.resolve(path), isUsableImage(url) {
                    return url
                }
            }
        }

        for resolver in resolvers {
            for folder in titleFolders {
                if let url = firstImage(in: folder, resolver: resolver) {
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
}
