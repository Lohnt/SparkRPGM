import Foundation
import UniformTypeIdentifiers

/// Accurate MIME types for everything an RPG Maker game can reference.
///
/// WebKit is strict about `application/wasm` and about JavaScript served with
/// a non-JS content type, so this table is deliberately explicit rather than
/// relying on `UTType`.
enum MimeTypes {

    private static let table: [String: String] = [
        // Documents / code
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "xhtml": "application/xhtml+xml; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "mjs": "application/javascript; charset=utf-8",
        "cjs": "application/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "csv": "text/csv; charset=utf-8",
        "wasm": "application/wasm",

        // Images
        "png": "image/png",
        "apng": "image/apng",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "jfif": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "svg": "image/svg+xml",
        "avif": "image/avif",

        // Audio
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "opus": "audio/ogg",
        "m4a": "audio/mp4",
        "mp4a": "audio/mp4",
        "aac": "audio/aac",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "flac": "audio/flac",
        "mid": "audio/midi",
        "midi": "audio/midi",
        "xm": "audio/x-xm",
        "mod": "audio/x-mod",
        "it": "audio/x-it",
        "s3m": "audio/x-s3m",

        // Video
        "webm": "video/webm",
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "ogv": "video/ogg",
        "mov": "video/quicktime",

        // Fonts
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "eot": "application/vnd.ms-fontobject",

        // Archives / misc binary (kept available for in-game downloads)
        "zip": "application/zip",
        "7z": "application/x-7z-compressed",
        "rar": "application/vnd.rar",
        "rgssad": "application/octet-stream",
        "rgss2a": "application/octet-stream",
        "rgss3a": "application/octet-stream",
        "rxdata": "application/octet-stream",
        "rvdata": "application/octet-stream",
        "rvdata2": "application/octet-stream",
        "rmmzsave": "application/octet-stream",
        "rpgsave": "application/octet-stream",
        "lsd": "application/octet-stream",
        "ldb": "application/octet-stream",
        "lmt": "application/octet-stream",
        "dat": "application/octet-stream",
        "bin": "application/octet-stream",
        "mem": "application/octet-stream",
        "data": "application/octet-stream",
    ]

    static func mimeType(for pathExtension: String) -> String {
        let key = pathExtension.lowercased()
        return table[key] ?? "application/octet-stream"
    }

    static func mimeType(for url: URL) -> String {
        mimeType(for: url.pathExtension)
    }

    /// Whether a file benefits from HTTP byte-range streaming.
    static func supportsByteRanges(_ pathExtension: String) -> Bool {
        switch pathExtension.lowercased() {
        case "webm", "mp4", "m4v", "ogv", "ogg", "oga", "m4a", "mp3", "mov":
            return true
        default:
            return false
        }
    }

    static func utType(for url: URL) -> UTType {
        UTType(filenameExtension: url.pathExtension) ?? .data
    }
}
