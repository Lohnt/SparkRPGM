import Foundation

/// Folder-name hygiene for `Documents/games/` and `Documents/save/`.
enum GameNames {

    private static let reserved: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
        ".", "..",
    ]

    static func sanitize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip Windows-illegal characters and path separators.
        let illegal = CharacterSet(charactersIn: "/\\:?*|\"<>#%")
            .union(.controlCharacters)
            .union(.newlines)
        name = name.components(separatedBy: illegal).joined(separator: " ")

        // Collapse whitespace.
        name = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")

        // Collapse repeated dots (also keeps ".." out of the name).
        while name.contains("..") {
            name = name.replacingOccurrences(of: "..", with: ".")
        }

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))

        if name.count > 96 {
            name = String(name.prefix(96)).trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        }

        if name.isEmpty {
            name = "Untitled Game"
        }

        if reserved.contains(name.lowercased()) {
            name += " Game"
        }

        return name
    }

    /// Cleans the noisy suffix Windows/APK builds tend to ship with.
    static func cleanedTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let noisySuffixes = [
            " - Windows", "-Windows", " (Windows)", "[Windows]",
            " - Win64", " - Win32", " (Win64)", " (Win32)",
            " - PC", " (PC)", " - Android", " (Android)", " - APK",
            " [APK]", "_apk", "-apk",
        ]
        for suffix in noisySuffixes {
            if title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
            }
        }

        let noisyPrefixes = ["www_", "www-", "game_", "Game-"]
        for prefix in noisyPrefixes where title.lowercased().hasPrefix(prefix.lowercased()) {
            title = String(title.dropFirst(prefix.count))
        }

        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return title.isEmpty ? raw : title
    }

    /// Returns a folder name that does not collide with `existing`.
    static func uniqueFolderName(base: String, existing: Set<String>) -> String {
        let sanitized = sanitize(base)
        guard existing.contains(sanitized) else { return sanitized }

        var index = 2
        while true {
            let candidate = "\(sanitized) (\(index))"
            if !existing.contains(candidate) { return candidate }
            index += 1
            if index > 9999 { return "\(sanitized) \(UUID().uuidString.prefix(8))" }
        }
    }

    static func existingGameFolders() -> Set<String> {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.games,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var names = Set<String>()
        for url in contents where AppPaths.isDirectory(url) {
            names.insert(url.lastPathComponent)
        }
        return names
    }
}
