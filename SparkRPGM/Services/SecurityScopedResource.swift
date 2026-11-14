import Foundation

/// A URL that keeps its security scope alive for as long as the object exists.
/// Used for files handed to us by Files.app / "Open in SparkRPGM".
final class SecurityScopedResource {

    let url: URL
    private let didStart: Bool

    init(_ url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Copies the resource into our own staging directory.
    ///
    /// Only used for small side-channel files (covers, images). Archives are
    /// read in place so multi-gigabyte games are never duplicated on disk.
    func copy(into directory: URL, preferredName: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let name = preferredName ?? url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.copyItem(at: url, to: destination)
        return destination
    }
}

/// Small bridge between the UIApplicationDelegate and SwiftUI.
///
/// File URLs handed to the app by the system ("Open in SparkRPGM") are queued
/// here; the library view drains the queue on launch and whenever the app
/// becomes active.
final class ImportInbox {

    static let shared = ImportInbox()
    static let didReceiveURLNotification = Notification.Name("SparkRPGM.ImportInbox.didReceiveURL")

    private var pending: [URL] = []
    private var scopes: [SecurityScopedResource] = []
    private let lock = NSLock()

    private init() {}

    func enqueue(_ url: URL) {
        guard url.isFileURL else { return }
        lock.lock()
        if !pending.contains(url) {
            pending.append(url)
            scopes.append(SecurityScopedResource(url))
        }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ImportInbox.didReceiveURLNotification, object: nil)
        }
    }

    func enqueue(contentsOf urls: [URL]) {
        urls.forEach(enqueue)
    }

    /// Returns and clears all queued URLs. The caller owns the returned files
    /// while the corresponding `SecurityScopedResource` objects stay alive.
    func drain() -> [URL] {
        lock.lock()
        let urls = pending
        pending.removeAll()
        // Keep scopes alive for the lifetime of the app; they are cheap and
        // guarantee that long extractions never lose access mid-flight.
        lock.unlock()
        return urls
    }

    var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }
}
