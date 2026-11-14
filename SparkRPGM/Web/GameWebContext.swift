import Foundation

/// Builds the per-game configuration that is injected before any game script
/// runs (`window.__SPARK_CONFIG__`).
struct GameWebContext {

    let game: Game
    let baseURLString: String
    let ogvBaseURL: String
    let easyRPGBaseURL: String

    static let maxSaveInjectionBytes = 48 * 1024 * 1024
    static let maxFileInjectionBytes = 4 * 1024 * 1024

    init(game: Game) {
        self.game = game
        let encoded = URLEncoding.encodePathComponent(game.folderName)
        self.baseURLString = "\(RPGMSchemeHandler.scheme)://\(RPGMSchemeHandler.host)/\(encoded)/"
        self.ogvBaseURL = "\(baseURLString)\(RPGMSchemeHandler.runtimePrefix)/ogv"
        self.easyRPGBaseURL = "\(baseURLString)\(RPGMSchemeHandler.runtimePrefix)/easyrpg"
    }

    var entryURL: URL {
        let encoded = URLEncoding.encodePathComponent(game.folderName)
        var path = ""
        if !game.entryPath.isEmpty {
            path = game.entryPath
                .split(separator: "/")
                .map { URLEncoding.encodePathComponent(String($0)) }
                .joined(separator: "/")
        }
        let suffix = path.isEmpty ? "index.html" : "\(path)/index.html"
        return URL(string: "\(RPGMSchemeHandler.scheme)://\(RPGMSchemeHandler.host)/\(encoded)/\(suffix)")
            ?? URL(string: "about:blank")!
    }

    /// Generated runtime host page served by the scheme handler.
    var easyRPGHostURL: URL {
        let encoded = URLEncoding.encodePathComponent(game.folderName)
        return URL(string: "\(RPGMSchemeHandler.scheme)://\(RPGMSchemeHandler.host)/\(encoded)/\(RPGMSchemeHandler.runtimePrefix)/easyrpg/host.html")
            ?? URL(string: "about:blank")!
    }

    // MARK: - Script

    func configurationScript(lowMemory: Bool) -> String {
        var dictionary: [String: Any] = [
            "gameFolder": game.folderName,
            "gameTitle": game.title,
            "engine": game.engine.rawValue,
            "scheme": RPGMSchemeHandler.scheme,
            "host": RPGMSchemeHandler.host,
            "baseURL": baseURLString,
            "ogvBase": ogvBaseURL,
            "easyrpgBase": easyRPGBaseURL,
            "saveExtension": game.engine.saveFileExtension,
            "nativeSave": true,
            "virtualCwd": "/" + game.folderName,
            "maxPixelRatio": 1.5,
            "capPixelRatio": lowMemory,
            "lowMemory": lowMemory,
            "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "platform": "ipados",
            "sparkVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "saves": saveManifest(),
            "fsFiles": fileManifest(),
        ]

        if let json = try? JSONSerialization.data(withJSONObject: dictionary, options: []) ,
           var string = String(data: json, encoding: .utf8) {
            // U+2028/U+2029 are line terminators in JS and must be escaped.
            string = string
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            return "window.__SPARK_CONFIG__ = \(string);"
        }

        dictionary = ["gameFolder": game.folderName]
        return "window.__SPARK_CONFIG__ = {\"gameFolder\":\"\(game.folderName.replacingOccurrences(of: "\"", with: "\\\""))\"};"
    }

    // MARK: - Saves

    /// Base64 encoded save files, small enough to live in memory so that the
    /// synchronous MV `StorageManager.loadFromLocalFile` API keeps working.
    private func saveManifest() -> [String: String] {
        let folder = AppPaths.saveFolder(forGame: game.folderName)
        guard AppPaths.isDirectory(folder),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [:] }

        var result: [String: String] = [:]
        var total = 0

        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            guard total + size <= Self.maxSaveInjectionBytes else {
                Log.app("Save preload cap reached; \(url.lastPathComponent) will load lazily (MV only)")
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            result[url.lastPathComponent] = data.base64EncodedString()
            total += size
        }
        return result
    }

    // MARK: - nw.js filesystem cache

    /// A lightweight snapshot of the game's small text files (package.json,
    /// config files, top-level listings) used by the `require('fs')` shim.
    private func fileManifest() -> [String: String] {
        let fm = FileManager.default
        let root = game.rootURL
        guard AppPaths.isDirectory(root) else { return [:] }

        var result: [String: String] = [:]
        var total = 0
        var visited = 0

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [:] }

        let skipNames: Set<String> = [
            "img", "audio", "movies", "graphics", "sound", "pictures", "faces",
            "characters", "tilesets", "battlebacks", "battlers", "animations",
            "system", "titles", "titles1", "titles2", "fogs", "panoramas",
            "parallaxes", "sv_actors", "sv_enemies", "effects", "icons",
            "se", "bgm", "bgs", "me", "music", "musics", "fonts", "font",
            "node_modules", ".git", "__MACOSX",
        ]
        let textExtensions: Set<String> = ["json", "ini", "txt", "cfg", "config", "properties", "xml", "js"]

        for case let url as URL in enumerator {
            visited += 1
            if visited > 5000 { break }

            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false

            if isDirectory {
                if skipNames.contains(name.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard textExtensions.contains(ext) else { continue }
            let size = values?.fileSize ?? 0
            guard size > 0, size <= 512 * 1024 else { continue }
            guard total + size <= Self.maxFileInjectionBytes else { continue }

            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var relative = url.path
            let rootPath = root.path
            if relative.hasPrefix(rootPath) {
                relative.removeFirst(rootPath.count)
            }
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            result[relative] = text
            total += size
        }

        return result
    }
}

enum URLEncoding {

    /// RFC 3986 unreserved characters only. Keeps folder names with spaces,
    /// emoji or CJK characters safe inside `rpgm://` URLs.
    static func encodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
