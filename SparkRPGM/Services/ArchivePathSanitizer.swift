import Foundation

/// Prevents zip-slip and cleans up archive entry names for APFS.
enum ArchivePathSanitizer {

    /// Returns a safe relative path, or nil when the entry should be skipped.
    static func safeRelativePath(for rawName: String) -> String? {
        var name = rawName.replacingOccurrences(of: "\\", with: "/")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return nil }

        // Absolute paths and drive letters are hostile.
        if name.hasPrefix("/") { return nil }
        if name.count >= 2 {
            let index = name.index(name.startIndex, offsetBy: 1)
            if name[index] == ":" { return nil }
        }

        var components: [String] = []
        for component in name.split(separator: "/", omittingEmptySubsequences: true) {
            let piece = String(component)
            if piece == "." { continue }
            if piece == ".." { return nil }
            if piece.contains("\0") { return nil }
            // macOS resource forks / metadata noise.
            if piece == "__MACOSX" { return nil }
            if piece == ".DS_Store" { return nil }
            components.append(piece)
        }

        guard !components.isEmpty else { return nil }

        // Keep individual components usable in Files.app.
        let cleaned = components.map { component -> String in
            var value = component
            if value.count > 200 {
                let ext = (value as NSString).pathExtension
                let base = (value as NSString).deletingPathExtension
                value = String(base.prefix(180)) + (ext.isEmpty ? "" : "." + ext)
            }
            return value
        }

        return cleaned.joined(separator: "/")
    }

    static func destinationURL(root: URL, relativePath: String) -> URL {
        var url = root
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }
}

/// Cooperative cancellation shared between the importer and the UI.
final class ImportCancellationToken {

    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
