import Foundation
import ZIPFoundation

/// Zips `Documents/save/<game>` into `Documents/backups/`.
enum SaveBackupService {

    enum BackupError: LocalizedError {
        case noSaveFolder
        case emptySaveFolder
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSaveFolder:
                return "This game does not have a save folder yet. Play it once and save in-game first."
            case .emptySaveFolder:
                return "There are no save files to back up yet."
            case .zipFailed(let reason):
                return "Backup failed: \(reason)"
            }
        }
    }

    private static let fileManager = FileManager.default

    @discardableResult
    static func backup(gameFolder: String) throws -> URL {
        let source = AppPaths.saveFolder(forGame: gameFolder)
        guard AppPaths.isDirectory(source) else { throw BackupError.noSaveFolder }

        let contents = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
        if contents.isEmpty {
            throw BackupError.emptySaveFolder
        }

        try fileManager.createDirectory(at: AppPaths.backups, withIntermediateDirectories: true, attributes: nil)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let safeName = GameNames.sanitize(gameFolder).replacingOccurrences(of: " ", with: "-")
        let destination = AppPaths.backups.appendingPathComponent("\(safeName)-\(formatter.string(from: Date())).zip")

        do {
            // ZIPFoundation streams the save folder to disk; save files are
            // tiny (a few hundred KB), so this is effectively instant.
            try fileManager.zipItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw BackupError.zipFailed(error.localizedDescription)
        }

        Log.app("Backed up \(gameFolder) -> \(destination.lastPathComponent)")
        return destination
    }

    static func listBackups() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: AppPaths.backups,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    static func backups(forGame gameFolder: String) -> [URL] {
        let safeName = GameNames.sanitize(gameFolder).replacingOccurrences(of: " ", with: "-")
        return listBackups().filter { $0.lastPathComponent.hasPrefix(safeName + "-") }
    }

    static func delete(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}
