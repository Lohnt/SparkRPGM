import Foundation
import UIKit

struct ImportResult {
    let folderName: String
    let title: String
    let engine: GameEngine
    let entryPath: String
}

/// The full "pick a file -> playable game in the library" pipeline.
///
/// Everything heavy happens on a background queue; archive extraction writes
/// directly to disk and never holds a whole game in memory.
final class ArchiveImporter {

    typealias ProgressHandler = (Double?, String) -> Void

    private let metadata: MetadataStore
    private let fileManager = FileManager.default

    init(metadata: MetadataStore = .shared) {
        self.metadata = metadata
    }

    // MARK: - Entry points

    func importItem(
        at url: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> ImportResult {
        if AppPaths.isDirectory(url) {
            return try importFolder(at: url, token: token, progress: progress)
        }
        return try importArchive(at: url, token: token, progress: progress)
    }

    // MARK: - Archive

    private func importArchive(
        at archiveURL: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> ImportResult {
        let stagingRoot = AppPaths.stagingFolder()
        let extraction = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true, attributes: nil)

        progress(0.02, "Preparing \(archiveURL.lastPathComponent)…")

        try ArchiveExtractor.extract(
            archiveURL: archiveURL,
            to: extraction,
            token: token
        ) { update in
            let fraction = update.fraction.map { 0.02 + $0 * 0.80 }
            progress(fraction, update.status)
        }

        guard !token.isCancelled else { throw ArchiveError.cancelled }

        progress(0.85, "Detecting game engine…")
        guard let detection = GameRootDetector.detect(in: extraction) else {
            throw ImportFailure.noGameFound
        }

        // Strip Android wrapper hooks before the game becomes visible.
        _ = APKSanitizer.sanitize(root: detection.rootURL)

        progress(0.90, "Installing \(detection.engine.displayName) game…")
        return try install(
            rootURL: detection.rootURL,
            engine: detection.engine,
            suggestedTitle: detection.title,
            stagingRoot: stagingRoot,
            token: token,
            progress: progress
        )
    }

    // MARK: - Folder

    private func importFolder(
        at folderURL: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> ImportResult {
        // Already inside our library? Nothing to do.
        if folderURL.standardizedFileURL.path.hasPrefix(AppPaths.games.standardizedFileURL.path + "/") {
            let name = folderURL.lastPathComponent
            let detection = GameRootDetector.detectForLibrary(at: folderURL)
            return ImportResult(
                folderName: name,
                title: metadata.metadata(for: name).displayName ?? name,
                engine: detection?.engine ?? .unknown,
                entryPath: detection?.entryPath ?? ""
            )
        }

        let stagingRoot = AppPaths.stagingFolder()
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: nil)

        progress(0.05, "Inspecting folder…")
        guard let detection = GameRootDetector.detect(in: folderURL, maxDepth: 5) else {
            throw ImportFailure.noGameFound
        }

        _ = APKSanitizer.sanitize(root: detection.rootURL)

        progress(0.25, "Copying \(detection.rootURL.lastPathComponent)…")
        let copy = stagingRoot.appendingPathComponent("game", isDirectory: true)

        do {
            // A same-volume move is instant; a cross-volume copy is unavoidable
            // when the folder comes from another provider.
            if folderURL.standardizedFileURL.path.hasPrefix(AppPaths.documents.standardizedFileURL.path) {
                try fileManager.moveItem(at: detection.rootURL, to: copy)
            } else {
                try fileManager.copyItem(at: detection.rootURL, to: copy)
            }
        } catch {
            throw ImportFailure.copyFailed(error.localizedDescription)
        }

        guard !token.isCancelled else { throw ArchiveError.cancelled }

        progress(0.92, "Installing…")
        return try install(
            rootURL: copy,
            engine: detection.engine,
            suggestedTitle: detection.title,
            stagingRoot: stagingRoot,
            token: token,
            progress: progress
        )
    }

    // MARK: - Install

    private func install(
        rootURL: URL,
        engine: GameEngine,
        suggestedTitle: String,
        stagingRoot: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws -> ImportResult {
        let existing = GameNames.existingGameFolders()
        let baseTitle = GameNames.cleanedTitle(suggestedTitle)
        let folderName = GameNames.uniqueFolderName(base: baseTitle, existing: existing)
        let destination = AppPaths.gameFolder(named: folderName)

        guard !token.isCancelled else { throw ArchiveError.cancelled }

        do {
            try fileManager.createDirectory(at: AppPaths.games, withIntermediateDirectories: true, attributes: nil)
            try fileManager.moveItem(at: rootURL, to: destination)
        } catch {
            throw ImportFailure.installFailed(error.localizedDescription)
        }

        // If the engine root was nested (for example `www/`) the move already
        // promoted it to the top of the destination, so entryPath is always "".
        AppPaths.ensureSaveFolder(forGame: folderName)

        var meta = GameMetadata()
        meta.displayName = folderName
        meta.engine = engine.rawValue
        meta.entryPath = ""
        meta.importedAt = Date()
        meta.byteSize = nil // computed asynchronously by GameStore
        metadata.set(meta, for: folderName)

        // Best effort cleanup of an empty staging folder.
        if let contents = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path), contents.isEmpty {
            try? fileManager.removeItem(at: stagingRoot)
        }

        progress(1.0, "Ready to play")
        Log.app("Imported \(folderName) [\(engine.rawValue)]")

        return ImportResult(
            folderName: folderName,
            title: folderName,
            engine: engine,
            entryPath: ""
        )
    }
}

enum ImportFailure: LocalizedError {
    case noGameFound
    case copyFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noGameFound:
            return "No RPG Maker game was found in this file. Expected index.html + js/rmmz_core.js (MZ), index.html + js/rpg_core.js (MV), RPG_RT.ldb + RPG_RT.lmt (2000/2003) or Data/System.rxdata (XP/VX/VX Ace)."
        case .copyFailed(let reason):
            return "The folder could not be copied: \(reason)"
        case .installFailed(let reason):
            return "The game could not be installed: \(reason)"
        }
    }
}
