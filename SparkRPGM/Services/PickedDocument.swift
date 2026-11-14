import Foundation

/// A file handed to the app by `UIDocumentPickerViewController` (or by
/// "Open in SparkRPGM").
///
/// The security scope is claimed as soon as the document arrives and is held
/// for as long as this object is alive. `ImportCoordinator` keeps the token
/// until extraction finishes, so an archive stays readable for the whole job.
///
/// iPadOS 15 file providers sometimes return URLs that pass
/// `startAccessingSecurityScopedResource()` yet still cannot be opened (local
/// Downloads, Google Drive, OneDrive). `prepare()` detects that and copies the
/// file into the app's temporary directory through `NSFileCoordinator`, so the
/// extractor always receives a genuinely readable local URL.
final class PickedDocument {

    enum ReadError: LocalizedError {
        case unreadable(String)
        case copyFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "Could not read \(name). Open Files, copy the archive into On My iPad / SparkRPGM, then import it again."
            case .copyFailed(let name, let reason):
                return "Could not copy \(name) out of its file provider: \(reason)"
            }
        }
    }

    let originalURL: URL

    /// The URL the extractor should read. Points at a temporary copy when the
    /// provider would not grant direct access.
    private(set) var url: URL

    private let didStartAccessing: Bool
    private var temporaryDirectory: URL?
    private var isPrepared = false
    private let lock = NSLock()

    init(url: URL) {
        self.originalURL = url
        self.url = url
        self.didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            originalURL.stopAccessingSecurityScopedResource()
        }
        if let directory = temporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var fileName: String {
        originalURL.lastPathComponent.isEmpty ? "archive" : originalURL.lastPathComponent
    }

    /// Returns a readable URL, staging a coordinated copy when the provider
    /// denies direct reads. Safe to call more than once.
    func prepare() throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        if isPrepared {
            return url
        }

        if Self.canRead(url) {
            isPrepared = true
            return url
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SparkRPGM-import-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(fileName)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw ReadError.copyFailed(fileName, error.localizedDescription)
        }

        var coordinationError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [.withoutChanges],
            error: &coordinationError
        ) { readableURL in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError = coordinationError {
            try? fileManager.removeItem(at: directory)
            throw ReadError.copyFailed(fileName, coordinationError.localizedDescription)
        }
        if let copyError = copyError {
            try? fileManager.removeItem(at: directory)
            throw ReadError.copyFailed(fileName, copyError.localizedDescription)
        }

        guard Self.canRead(destination) else {
            try? fileManager.removeItem(at: directory)
            throw ReadError.unreadable(fileName)
        }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var staged = destination
        try? staged.setResourceValues(values)

        temporaryDirectory = directory
        url = destination
        isPrepared = true
        Log.app("Staged \(fileName) from its file provider into temporary storage")
        return destination
    }

    /// Reads one byte (or lists a directory) so a provider that reports the
    /// file but denies access is caught before extraction starts.
    private static func canRead(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }

        if isDirectory.boolValue {
            return (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }
}
