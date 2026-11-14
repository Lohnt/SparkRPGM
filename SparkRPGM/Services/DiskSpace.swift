import Foundation

enum DiskSpace {

    /// Bytes available for "important" usage (matches what iOS lets us write).
    static func availableBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    static func hasRoom(forBytes bytes: Int64, at url: URL) -> Bool {
        guard let available = availableBytes(at: url) else { return true }
        // Keep 512 MB headroom for saves, thumbnails and iOS itself.
        return available > bytes + 512 * 1024 * 1024
    }

    static func formattedAvailable(at url: URL) -> String? {
        guard let bytes = availableBytes(at: url) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
