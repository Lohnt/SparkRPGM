import Foundation

struct GameDetection {
    let rootURL: URL
    let engine: GameEngine
    let title: String
    /// Path of `rootURL` relative to the folder that was scanned ("" for a
    /// clean imported game, "www" for a nested web build, ...).
    let entryPath: String
}

/// Finds the real engine root inside an extracted archive (or inside a folder
/// the user copied in through Files.app).
enum GameRootDetector {

    private static let skippedDirectoryNames: Set<String> = [
        "__MACOSX", ".git", ".svn", "node_modules", ".DS_Store", "System Volume Information",
        "$RECYCLE.BIN", "lost+found",
    ]

    // MARK: - Public API

    static func detect(in searchRoot: URL, maxDepth: Int = 6) -> GameDetection? {
        let fileManager = FileManager.default
        guard AppPaths.isDirectory(searchRoot) else { return nil }

        var queue: [(url: URL, relative: String, depth: Int)] = [(searchRoot, "", 0)]
        var best: (detection: GameDetection, score: Int, depth: Int)?

        var visited = 0
        var index = 0

        while index < queue.count {
            let item = queue[index]
            index += 1
            visited += 1
            if visited > 4000 { break }

            if let engine = candidateEngine(at: item.url) {
                let detection = GameDetection(
                    rootURL: item.url,
                    engine: engine,
                    title: title(for: item.url, engine: engine),
                    entryPath: item.relative
                )
                let specificity: Int
                switch engine {
                case .rpgMakerMZ, .rpgMakerMV, .rpgMaker2000, .rpgMaker2003,
                     .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
                    specificity = 3
                case .web:
                    specificity = 1
                case .unknown:
                    specificity = 0
                }

                // APK wrapper: assets/www always wins.
                let lower = item.relative.lowercased()
                let apkBoost = lower.hasSuffix("assets/www") ? 2 : 0
                let wwwBoost = lower.hasSuffix("/www") || lower == "www" ? 1 : 0
                let score = specificity * 10 + apkBoost * 4 + wwwBoost

                if let current = best {
                    if score > current.score || (score == current.score && item.depth < current.depth) {
                        best = (detection, score, item.depth)
                    }
                } else {
                    best = (detection, score, item.depth)
                }

                // A specific engine at depth 0 is unbeatable.
                if specificity >= 3 && item.depth == 0 { break }
            }

            guard item.depth < maxDepth else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(
                at: item.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in contents {
                let name = child.lastPathComponent
                if skippedDirectoryNames.contains(name) { continue }
                if name.hasPrefix(".") { continue }
                guard AppPaths.isDirectory(child) else { continue }
                // Do not descend into asset folders that cannot hold an engine root.
                if isAssetFolderName(name) { continue }
                let relative = item.relative.isEmpty ? name : item.relative + "/" + name
                queue.append((child, relative, item.depth + 1))
            }
        }

        return best?.detection
    }

    /// Detects the engine of an already-imported game folder.
    static func detectEngine(at directory: URL) -> GameEngine? {
        candidateEngine(at: directory)
    }

    /// Locates the entry folder of an imported game (supports manually copied
    /// `www/` wrappers, APK extractions and nested build folders).
    static func detectForLibrary(at gameFolder: URL) -> GameDetection? {
        detect(in: gameFolder, maxDepth: 4)
    }

    // MARK: - Engine markers

    /// Returns the engine if `directory` itself is a valid engine root.
    static func candidateEngine(at directory: URL) -> GameEngine? {
        let resolver = CaseInsensitiveFileResolver(root: directory)
        let fm = FileManager.default

        func exists(_ path: String) -> Bool {
            guard let url = resolver.resolve(path) else { return false }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            return !isDir.boolValue
        }

        func existsDir(_ path: String) -> Bool {
            resolver.resolveDirectory(path) != nil
        }

        // RPG Maker MZ
        if exists("index.html") && (exists("js/rmmz_core.js") || exists("js/rmmz_managers.js")) {
            return .rpgMakerMZ
        }

        // RPG Maker MV (standard + modified: some builds rename core files)
        if exists("index.html") {
            if exists("js/rpg_core.js") || exists("js/rpg_managers.js") || exists("js/rpg_objects.js") {
                return .rpgMakerMV
            }
            // Modified MV builds occasionally flatten the js folder.
            if exists("rpg_core.js") || exists("rmmz_core.js") {
                return exists("rmmz_core.js") ? .rpgMakerMZ : .rpgMakerMV
            }
        }

        // RPG Maker 2000 / 2003
        if exists("RPG_RT.ldb") && exists("RPG_RT.lmt") {
            return lcfVersion(at: directory)
        }

        // RPG Maker XP / VX / VX Ace
        if exists("Game.rgss3a") { return .rpgMakerVXAce }
        if exists("Game.rgss2a") { return .rpgMakerVX }
        if exists("Game.rgssad") { return .rpgMakerXP }

        if exists("Data/System.rvdata2") { return .rpgMakerVXAce }
        if exists("Data/System.rvdata") { return .rpgMakerVX }
        if exists("Data/System.rxdata") { return .rpgMakerXP }

        // VX Ace sometimes keeps the archive lowercase.
        if exists("game.rgss3a") { return .rpgMakerVXAce }
        if exists("game.rgss2a") { return .rpgMakerVX }
        if exists("game.rgssad") { return .rpgMakerXP }

        // Plain HTML5 build (index.html with no recognisable Maker core).
        if exists("index.html") {
            return .web
        }

        // A folder of loose RGSS data without System.rxdata is still XP-ish.
        if existsDir("Data") && existsDir("Graphics") && (exists("Data/Actors.rxdata") || exists("Data/Actors.rvdata2")) {
            return exists("Data/Actors.rxdata") ? .rpgMakerXP : .rpgMakerVXAce
        }

        return nil
    }

    private static func isAssetFolderName(_ name: String) -> Bool {
        switch name.lowercased() {
        case "img", "audio", "graphics", "sound", "se", "bgm", "bgs", "me", "movies",
             "fonts", "font", "data", "js", "css", "libs", "res", "resources",
             "pics", "pictures", "faces", "characters", "tilesets", "animations", "battlebacks",
             "battlers", "system", "titles", "titles1", "titles2", "fogs", "panoramas",
             "parallaxes", "charasets", "chipsets", "musics", "sounds",
             "battle", "monsters", "battlecharset", "battleweapon", "frame", "gameover",
             "title", "windowskins", "icons", "transitions", "enemies",
             "sv_actors", "sv_enemies", "effects", "layouts":
            return true
        default:
            return false
        }
    }

    // MARK: - RPG Maker 2000 / 2003

    private static func lcfVersion(at directory: URL) -> GameEngine {
        let resolver = CaseInsensitiveFileResolver(root: directory)
        if let url = resolver.resolve("RPG_RT.ldb"),
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 32)) ?? Data()
            let bytes = [UInt8](header)
            if bytes.count >= 15 {
                let magic = String(bytes: bytes[0..<11], encoding: .ascii) ?? ""
                if magic.hasPrefix("LcfDataBase") {
                    let version = UInt32(bytes[11])
                        | (UInt32(bytes[12]) << 8)
                        | (UInt32(bytes[13]) << 16)
                        | (UInt32(bytes[14]) << 24)
                    if version >= 2003 && version < 2100 { return .rpgMaker2003 }
                    if version == 2000 { return .rpgMaker2000 }
                }
            }
        }

        // Fall back to RPG_RT.ini hints (2k3 builds usually embed "2003").
        if let ini = resolver.resolve("RPG_RT.ini"),
           let text = try? String(contentsOf: ini, encoding: .utf8),
           text.lowercased().contains("2003") {
            return .rpgMaker2003
        }
        return .rpgMaker2000
    }

    // MARK: - Titles

    static func title(for directory: URL, engine: GameEngine) -> String {
        let resolver = CaseInsensitiveFileResolver(root: directory)

        switch engine {
        case .rpgMakerMZ, .rpgMakerMV, .web:
            if let systemURL = resolver.resolve("data/System.json"),
               let data = try? Data(contentsOf: systemURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["gameTitle"] as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            // Some builds ship `data/system.json` under a different name.
            if let packageURL = resolver.resolve("package.json"),
               let data = try? Data(contentsOf: packageURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let title = json["window"] as? [String: Any], let t = title["title"] as? String, !t.isEmpty {
                    return t
                }
                if let name = json["name"] as? String, !name.isEmpty {
                    return name
                }
            }

        case .rpgMaker2000, .rpgMaker2003:
            if let ini = resolver.resolve("RPG_RT.ini"),
               let text = try? String(contentsOf: ini, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let lower = trimmed.lowercased()
                    if lower.hasPrefix("gametitle=") {
                        let value = String(trimmed.dropFirst("gametitle=".count))
                        if !value.isEmpty { return value }
                    }
                    if lower.hasPrefix("title=") {
                        let value = String(trimmed.dropFirst("title=".count))
                        if !value.isEmpty { return value }
                    }
                }
            }

        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            if let ini = resolver.resolve("Game.ini"),
               let text = try? String(contentsOf: ini, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.lowercased().hasPrefix("title=") {
                        let value = String(trimmed.dropFirst("title=".count))
                        if !value.isEmpty { return value }
                    }
                }
            }

        case .unknown:
            break
        }

        // Fall back to the folder name, cleaned of build noise.
        return GameNames.cleanedTitle(directory.lastPathComponent)
    }
}
