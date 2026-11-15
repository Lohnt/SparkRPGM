import Foundation
import UIKit

/// The library model. Owns scanning, renaming, deleting, covers and metadata.
final class GameStore: ObservableObject {

    private static let hiddenGamesDefaultsKey = "sparkrpgm.hiddenGames.v1"

    @Published private(set) var games: [Game] = []
    @Published private(set) var hiddenFolderNames: Set<String> = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    let metadata: MetadataStore
    private let fileManager = FileManager.default
    private var hasScanned = false
    private var rescanRequested = false
    private var toastWorkItem: DispatchWorkItem?

    init(metadata: MetadataStore = .shared) {
        self.metadata = metadata
        if let stored = UserDefaults.standard.array(forKey: Self.hiddenGamesDefaultsKey) as? [String] {
            self.hiddenFolderNames = Set(stored)
        }
    }

    // MARK: - Scanning

    func scan() {
        guard !isScanning else {
            // An import can finish while the initial scan is still running.
            // Remember to run one more pass instead of dropping the refresh.
            rescanRequested = true
            return
        }
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let scanned = self.performScan()
            DispatchQueue.main.async {
                self.games = scanned
                self.isScanning = false
                self.hasScanned = true
                if !scanned.isEmpty {
                    self.refreshMissingSizes()
                }
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scan()
                }
            }
        }
    }

    private func performScan() -> [Game] {
        let folders: [URL]
        do {
            folders = try fileManager.contentsOfDirectory(
                at: AppPaths.games,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.error("Library scan failed", error: error)
            return []
        }

        var results: [Game] = []
        results.reserveCapacity(folders.count)

        for folder in folders {
            guard AppPaths.isDirectory(folder) else { continue }
            let name = folder.lastPathComponent
            let meta = metadata.metadata(for: name)

            let detection = GameRootDetector.detectForLibrary(at: folder)
            let engine = detection?.engine ?? meta.resolvedEngine ?? .unknown
            let entryPath = detection?.entryPath ?? meta.entryPath ?? ""

            var title = meta.displayName ?? GameNames.cleanedTitle(name)
            if meta.customTitle != true,
               (meta.displayName == nil || meta.displayName == name),
               let detectedTitle = detection?.title,
               !detectedTitle.isEmpty {
                title = detectedTitle
            }
            title = GameNames.cleanedTitle(title)

            let engineRoot = entryPath.isEmpty ? folder : folder.appendingPathComponent(entryPath, isDirectory: true)
            let customCover = AppPaths.coverFile(forGame: name)
            let hasCustomCover = fileManager.fileExists(atPath: customCover.path)

            let cover: URL?
            if hasCustomCover {
                cover = customCover
            } else if let cached = AppPaths.autoCoverURL(forGame: name) {
                cover = cached
            } else if let found = GameCoverFinder.find(inGameRoot: folder, engineRoot: engineRoot) {
                // Cache once so the grid never re-walks the game on every scan.
                cover = GameCoverFinder.cache(candidate: found, forGame: name) ?? found
            } else {
                cover = Self.discoverCover(in: engineRoot, engine: engine)
            }

            // Cache the detection result so the next launch is instant.
            if meta.engine != engine.rawValue || meta.entryPath != entryPath {
                metadata.update(name) { value in
                    value.engine = engine.rawValue
                    value.entryPath = entryPath
                }
            }

            results.append(Game(
                folderName: name,
                title: title,
                engine: engine,
                entryPath: entryPath,
                byteSize: meta.byteSize ?? 0,
                lastPlayed: meta.lastPlayedAt,
                playSeconds: meta.playTimeSeconds ?? 0,
                lineColorHex: meta.accentColorHex,
                hasCustomCover: hasCustomCover,
                coverURL: cover,
                importedAt: meta.importedAt
            ))
        }

        return results.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Computes sizes for new games without blocking the first paint.
    private func refreshMissingSizes() {
        let missing = games.filter { $0.byteSize <= 0 }
        guard !missing.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            for game in missing {
                let size = AppPaths.size(of: game.rootURL)
                guard size > 0 else { continue }
                self.metadata.update(game.folderName) { $0.byteSize = size }
                DispatchQueue.main.async {
                    if let index = self.games.firstIndex(where: { $0.folderName == game.folderName }) {
                        self.games[index].byteSize = size
                    }
                }
            }
        }
    }

    // MARK: - Mutations

    func markPlayed(_ game: Game) {
        let now = Date()
        metadata.update(game.folderName) { $0.lastPlayedAt = now }
        if let index = games.firstIndex(where: { $0.folderName == game.folderName }) {
            games[index].lastPlayed = now
        }
    }

    /// Re-reads the (already persisted) per-game metadata after a play session.
    /// Cheap enough to call on every player dismissal — no directory walk.
    func refreshMetadata() {
        let snapshot = metadata.all()
        var updated = games
        var changed = false
        for index in updated.indices {
            guard let meta = snapshot[updated[index].folderName] else { continue }
            let play = meta.playTimeSeconds ?? 0
            if updated[index].playSeconds != play { updated[index].playSeconds = play; changed = true }
            if updated[index].lastPlayed != meta.lastPlayedAt { updated[index].lastPlayed = meta.lastPlayedAt; changed = true }
            if updated[index].lineColorHex != meta.accentColorHex {
                updated[index].lineColorHex = meta.accentColorHex
                changed = true
            }
        }
        if changed { games = updated }
    }

    /// `nil` clears the per-game override and falls back to the launcher colour.
    func setLineColor(_ hex: String?, for game: Game) {
        metadata.update(game.folderName) { $0.accentColorHex = hex }
        if let index = games.firstIndex(where: { $0.folderName == game.folderName }) {
            games[index].lineColorHex = hex
        }
    }

    @discardableResult
    func rename(_ game: Game, to newTitle: String) throws -> String {
        let existing = GameNames.existingGameFolders().subtracting([game.folderName])
        let folderName = GameNames.uniqueFolderName(base: newTitle, existing: existing)
        guard folderName != game.folderName else {
            metadata.update(game.folderName) { $0.displayName = folderName }
            return folderName
        }

        let source = AppPaths.gameFolder(named: game.folderName)
        let destination = AppPaths.gameFolder(named: folderName)

        try fileManager.moveItem(at: source, to: destination)

        // Move the save folder so existing saves follow the rename.
        let oldSave = AppPaths.saveFolder(forGame: game.folderName)
        if fileManager.fileExists(atPath: oldSave.path) {
            let newSave = AppPaths.saveFolder(forGame: folderName)
            try? fileManager.moveItem(at: oldSave, to: newSave)
        }

        // Move a custom cover, if present.
        let oldCover = AppPaths.coverFile(forGame: game.folderName)
        if fileManager.fileExists(atPath: oldCover.path) {
            try? fileManager.removeItem(at: AppPaths.coverFile(forGame: folderName))
            try? fileManager.moveItem(at: oldCover, to: AppPaths.coverFile(forGame: folderName))
        }
        GameCoverFinder.move(from: game.folderName, to: folderName)

        metadata.move(from: game.folderName, to: folderName)
        metadata.update(folderName) { value in
            value.displayName = folderName
            value.customTitle = true
        }

        if hiddenFolderNames.remove(game.folderName) != nil {
            hiddenFolderNames.insert(folderName)
            persistHiddenGames()
        }

        toast("Renamed to \(folderName)")
        scan()
        return folderName
    }

    func delete(_ game: Game) throws {
        let folder = game.rootURL
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        let save = AppPaths.saveFolder(forGame: game.folderName)
        if fileManager.fileExists(atPath: save.path) {
            try? fileManager.removeItem(at: save)
        }
        let cover = AppPaths.coverFile(forGame: game.folderName)
        if fileManager.fileExists(atPath: cover.path) {
            try? fileManager.removeItem(at: cover)
        }
        GameCoverFinder.clear(forGame: game.folderName)
        metadata.remove(game.folderName)
        games.removeAll { $0.folderName == game.folderName }
        if hiddenFolderNames.remove(game.folderName) != nil {
            persistHiddenGames()
        }
        toast("Deleted \(game.title)")
    }

    // MARK: - Hidden Games

    var hiddenGames: [Game] {
        games.filter { hiddenFolderNames.contains($0.folderName) }
    }

    func isGameHidden(_ game: Game) -> Bool {
        hiddenFolderNames.contains(game.folderName)
    }

    func hideGame(_ game: Game) {
        hiddenFolderNames.insert(game.folderName)
        persistHiddenGames()
        toast("Hidden \(game.title)")
    }

    func unhideGame(folderName: String) {
        hiddenFolderNames.remove(folderName)
        persistHiddenGames()
        if let game = games.first(where: { $0.folderName == folderName }) {
            toast("Restored \(game.title)")
        } else {
            toast("Restored game")
        }
    }

    private func persistHiddenGames() {
        UserDefaults.standard.set(Array(hiddenFolderNames), forKey: Self.hiddenGamesDefaultsKey)
    }

    func setCustomCover(_ image: UIImage, for game: Game) throws {
        guard let data = ImageTools.jpegData(from: image, maxPixel: 1200, quality: 0.9) else {
            throw NSError(domain: "SparkRPGM", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "That image could not be converted.",
            ])
        }
        try fileManager.createDirectory(at: AppPaths.covers, withIntermediateDirectories: true, attributes: nil)
        let destination = AppPaths.coverFile(forGame: game.folderName)
        try data.write(to: destination, options: .atomic)
        ThumbnailCache.shared.clear()

        if let index = games.firstIndex(where: { $0.folderName == game.folderName }) {
            games[index].hasCustomCover = true
            games[index].coverURL = destination
        }
        toast("Cover updated")
    }

    func removeCustomCover(for game: Game) {
        try? fileManager.removeItem(at: AppPaths.coverFile(forGame: game.folderName))
        ThumbnailCache.shared.clear()
        scan()
    }

    @discardableResult
    func backupSaves(for game: Game) throws -> URL {
        let url = try SaveBackupService.backup(gameFolder: game.folderName)
        toast("Backup saved to backups/\(url.lastPathComponent)")
        return url
    }

    // MARK: - Toast

    func toast(_ message: String) {
        DispatchQueue.main.async {
            self.toastMessage = message
        }
        toastWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
    }

    // MARK: - Cover discovery

    static func discoverCover(in root: URL, engine: GameEngine) -> URL? {
        let resolver = CaseInsensitiveFileResolver(root: root)

        var candidateDirectories: [String] = []
        switch engine {
        case .rpgMakerMZ, .rpgMakerMV, .web:
            candidateDirectories = ["img/titles1", "img/titles2", "img/pictures", "img/system"]
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            candidateDirectories = ["Graphics/Titles", "Graphics/Pictures", "Graphics/System"]
        case .rpgMaker2000, .rpgMaker2003:
            candidateDirectories = ["Title", "System", "Pictures", "GameOver", "Backdrop"]
        case .unknown:
            candidateDirectories = ["img/titles1", "Graphics/Titles", "Title"]
        }

        var firstImage: URL?
        for relative in candidateDirectories {
            guard let directory = resolver.resolveDirectory(relative),
                  let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            let images = contents
                .filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

            if firstImage == nil { firstImage = images.first }

            if let preferred = images.first(where: { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                return name == "title" || name == "gameover" || name.contains("title")
            }) {
                return preferred
            }
        }
        return firstImage
    }
}
