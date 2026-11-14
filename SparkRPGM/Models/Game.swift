import Foundation

/// A game that lives in `Documents/games/<folderName>`.
struct Game: Identifiable, Equatable {

    let folderName: String
    var title: String
    var engine: GameEngine
    /// Relative path from the game folder to the real engine root ("" or "www").
    var entryPath: String
    var byteSize: Int64
    var lastPlayed: Date?
    var hasCustomCover: Bool
    var coverURL: URL?
    var importedAt: Date?

    var id: String { folderName }

    var rootURL: URL { AppPaths.gameFolder(named: folderName) }

    /// Folder containing `index.html` / `RPG_RT.ldb`.
    var engineRootURL: URL {
        guard !entryPath.isEmpty else { return rootURL }
        return rootURL.appendingPathComponent(entryPath, isDirectory: true)
    }

    var entryFileURL: URL {
        engineRootURL.appendingPathComponent("index.html")
    }

    /// Folder whose relative path is used by the `rpgm://` scheme.
    /// The scheme handler always roots at the game folder so that manual
    /// `www/` wrappers keep working without rewriting game code.
    var webserverRootURL: URL { rootURL }

    var formattedSize: String {
        guard byteSize > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var formattedLastPlayed: String? {
        guard let lastPlayed = lastPlayed else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastPlayed, relativeTo: Date())
    }

    static func == (lhs: Game, rhs: Game) -> Bool {
        lhs.folderName == rhs.folderName
            && lhs.title == rhs.title
            && lhs.engine == rhs.engine
            && lhs.byteSize == rhs.byteSize
            && lhs.lastPlayed == rhs.lastPlayed
            && lhs.hasCustomCover == rhs.hasCustomCover
            && lhs.coverURL == rhs.coverURL
    }
}

/// Persisted per-game overrides, keyed by folder name.
struct GameMetadata: Codable {

    var displayName: String?
    var engine: String?
    var entryPath: String?
    var byteSize: Int64?
    var lastPlayed: Date?
    var playSeconds: Double?
    var importedAt: Date?
    /// `true` once the user renamed the game, so the library never replaces
    /// their title with the one detected inside the game data.
    var customTitle: Bool?

    var resolvedEngine: GameEngine? {
        guard let engine = engine else { return nil }
        return GameEngine(rawValue: engine)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        entryPath = try container.decodeIfPresent(String.self, forKey: .entryPath)
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        playSeconds = try container.decodeIfPresent(Double.self, forKey: .playSeconds)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        customTitle = try container.decodeIfPresent(Bool.self, forKey: .customTitle)
    }
}

/// JSON-backed metadata store. Small, fast, and resilient to corruption.
final class MetadataStore {

    static let shared = MetadataStore()

    private var cache: [String: GameMetadata]
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL = AppPaths.metadataFile) {
        self.fileURL = fileURL
        self.cache = MetadataStore.load(from: fileURL)
    }

    func metadata(for folder: String) -> GameMetadata {
        lock.lock()
        defer { lock.unlock() }
        return cache[folder] ?? GameMetadata()
    }

    func all() -> [String: GameMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    func update(_ folder: String, _ mutate: (inout GameMetadata) -> Void) {
        lock.lock()
        var value = cache[folder] ?? GameMetadata()
        mutate(&value)
        cache[folder] = value
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
    }

    func set(_ metadata: GameMetadata, for folder: String) {
        update(folder) { $0 = metadata }
    }

    func remove(_ folder: String) {
        lock.lock()
        cache.removeValue(forKey: folder)
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
    }

    /// Copies metadata from one folder to another (used by rename).
    func move(from oldFolder: String, to newFolder: String) {
        lock.lock()
        var value = cache.removeValue(forKey: oldFolder) ?? GameMetadata()
        value.displayName = newFolder
        value.customTitle = true
        cache[newFolder] = value
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: GameMetadata]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try AppPaths.atomicWrite(data, to: fileURL)
        } catch {
            Log.error("Unable to persist metadata", error: error)
        }
    }

    private static func load(from url: URL) -> [String: GameMetadata] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: GameMetadata].self, from: data)
        } catch {
            Log.error("Metadata decode failed; starting fresh", error: error)
            return [:]
        }
    }
}
