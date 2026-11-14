import Foundation

/// Resolves a relative path inside a directory the way a case-insensitive
/// filesystem would, with an in-memory cache.
///
/// iOS uses case-sensitive APFS. RPG Maker games are authored on Windows and
/// macOS and routinely reference `IMG/Pictures/Foo.PNG` when the file on disk
/// is `img/pictures/foo.png`. Every miss is retried component by component
/// against a lowercased directory index.
final class CaseInsensitiveFileResolver {

    private let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// Input relative path -> resolved URL (nil = known miss).
    private var resultCache: [String: URL?] = [:]
    /// Directory relative path -> [lowercased name: actual name]
    private var directoryCache: [String: [String: String]] = [:]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func invalidate() {
        lock.lock()
        resultCache.removeAll(keepingCapacity: true)
        directoryCache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Resolves `relativePath` to an existing URL, or nil.
    /// Traversal outside of `root` is always refused.
    func resolve(_ relativePath: String) -> URL? {
        let normalised = Self.normalise(relativePath)
        guard !normalised.isEmpty, !Self.containsTraversal(normalised) else { return nil }

        lock.lock()
        if let cached = resultCache[normalised] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let components = normalised.split(separator: "/").map(String.init)
        var current = root
        var actualComponents: [String] = []

        for component in components {
            let candidate = current.appendingPathComponent(component)
            if fileManager.fileExists(atPath: candidate.path) {
                current = candidate
                actualComponents.append(component)
                continue
            }

            let parentRelative = actualComponents.joined(separator: "/")
            guard let listing = listing(forDirectory: parentRelative),
                  let actualName = listing[component.lowercased()] else {
                cache(normalised, nil)
                return nil
            }
            current = current.appendingPathComponent(actualName)
            actualComponents.append(actualName)
        }

        let exists = fileManager.fileExists(atPath: current.path)
        let result: URL? = exists ? current : nil
        cache(normalised, result)
        return result
    }

    func exists(_ relativePath: String) -> Bool {
        resolve(relativePath) != nil
    }

    /// Case-insensitively checks a path that might itself be a directory.
    func resolveDirectory(_ relativePath: String) -> URL? {
        guard let url = resolve(relativePath) else { return nil }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    // MARK: - Internals

    private func cache(_ key: String, _ value: URL?) {
        lock.lock()
        resultCache[key] = value
        lock.unlock()
    }

    private func listing(forDirectory relative: String) -> [String: String]? {
        lock.lock()
        if let cached = directoryCache[relative] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            lock.lock()
            directoryCache[relative] = [:]
            lock.unlock()
            return nil
        }

        var map: [String: String] = [:]
        map.reserveCapacity(names.count)
        for name in names {
            map[name.lowercased()] = name
        }

        lock.lock()
        directoryCache[relative] = map
        lock.unlock()
        return map
    }

    static func normalise(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        value = value.removingPercentEncoding ?? value
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        return parts.joined(separator: "/")
    }

    static func containsTraversal(_ path: String) -> Bool {
        if path.contains("..") { return true }
        if path.contains("\0") { return true }
        // Windows drive letters must never escape the root.
        if path.count >= 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" { return true }
        return false
    }
}
