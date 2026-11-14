import Foundation

/// Centralised, lazily-created layout of the app's Documents sandbox.
///
/// On device this is exposed to the Files app as:
///
///     On My iPad / SparkRPGM /
///         games/  save/  backups/  chocofilepickerfixfolder/  theme/
///
/// Every path is derived from `Documents` so it also works in the simulator.
enum AppPaths {

    static let fileManager = FileManager.default

    // MARK: - Root folders (stable, user visible)

    static var documents: URL {
        if let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return url
        }
        // Extremely unlikely fallback; keeps the app from crashing on a broken container.
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SparkRPGMDocuments", isDirectory: true)
    }

    static var games: URL { documents.appendingPathComponent("games", isDirectory: true) }
    static var saves: URL { documents.appendingPathComponent("save", isDirectory: true) }
    static var backups: URL { documents.appendingPathComponent("backups", isDirectory: true) }
    static var pickerFix: URL { documents.appendingPathComponent("chocofilepickerfixfolder", isDirectory: true) }
    static var theme: URL { documents.appendingPathComponent("theme", isDirectory: true) }
    static var wallpaper: URL { theme.appendingPathComponent("wallpaper.jpg") }

    // MARK: - Private scaffolding (hidden from Files.app by the dot prefix)

    static var internalRoot: URL { documents.appendingPathComponent(".spark", isDirectory: true) }
    static var staging: URL { documents.appendingPathComponent(".staging", isDirectory: true) }
    static var covers: URL { internalRoot.appendingPathComponent("covers", isDirectory: true) }
    static var metadataFile: URL { internalRoot.appendingPathComponent("metadata.json") }
    static var nwfsRoot: URL { internalRoot.appendingPathComponent("nwfs", isDirectory: true) }
    static var runtimeCache: URL { internalRoot.appendingPathComponent("runtime", isDirectory: true) }

    // MARK: - Bootstrap

    private static var didBootstrap = false

    /// Creates every folder SparkRPGM relies on. Safe to call repeatedly and
    /// from any thread (guarded by a lock).
    @discardableResult
    static func bootstrap() -> Bool {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }

        var ok = true
        let folders: [URL] = [
            games, saves, backups, pickerFix, theme, internalRoot, staging, covers, nwfsRoot, runtimeCache,
        ]

        for folder in folders {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
            } catch {
                ok = false
                NSLog("[SparkRPGM] Unable to create %@: %@", folder.path, error.localizedDescription)
            }
        }

        // A real file inside chocofilepickerfixfolder forces iPadOS Files and
        // UIDocumentPickerViewController to index the app's directory even when
        // every other folder is empty.
        let keep = pickerFix.appendingPathComponent(".keep")
        if !fileManager.fileExists(atPath: keep.path) {
            fileManager.createFile(atPath: keep.path, contents: Data("sparkrpgm-picker-fix\n".utf8), attributes: nil)
        }

        // A human readable map so people can find their content in Files.app.
        let readme = documents.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readme.path) {
            let text = """
            SparkRPGM
            =========

            games/                     Extracted RPG Maker games. Each folder is a game root
                                       (index.html + js/ for MV/MZ, RPG_RT.ldb for 2000/2003,
                                       Data/System.* for XP/VX/VX Ace).
            save/                      Physical save files, one folder per game
                                       (file1.rmmzsave, file1.rpgsave, Save01.lsd, ...).
            backups/                   Zip backups created from a game card's long-press menu.
            chocofilepickerfixfolder/  Keeps the Files.app directory index alive.
            theme/                     wallpaper.jpg and launcher appearance data.

            Drop a .zip / .7z / .rar / .apk anywhere in this folder and import it
            with the + button, or copy an already extracted game into games/ and
            pull to refresh the library.
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }

        excludeFromBackup(games)
        excludeFromBackup(staging)

        didBootstrap = ok
        return ok
    }

    private static let bootstrapLock = NSLock()

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    // MARK: - Derived folders

    static func gameFolder(named name: String) -> URL {
        games.appendingPathComponent(name, isDirectory: true)
    }

    static func saveFolder(forGame name: String) -> URL {
        saves.appendingPathComponent(name, isDirectory: true)
    }

    /// Ensures `save/<game>` exists and returns it.
    @discardableResult
    static func ensureSaveFolder(forGame name: String) -> URL {
        let url = saveFolder(forGame: name)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func coverFile(forGame name: String, fileExtension: String = "jpg") -> URL {
        covers.appendingPathComponent("\(name).\(fileExtension)")
    }

    static func stagingFolder() -> URL {
        staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Helpers

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func size(of url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Writes data atomically by staging into a sibling temp file first.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            _ = try? fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temp, to: url)
    }
}
