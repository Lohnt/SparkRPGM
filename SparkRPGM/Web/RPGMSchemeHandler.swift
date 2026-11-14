import Foundation
import WebKit

/// Serves a game over `rpgm://game/<GameFolder>/...`.
///
/// Highlights:
/// * Byte-range (`206 Partial Content`) responses streamed with `FileHandle`
///   in 256 KB chunks, so hour-long `.webm` cutscenes never become a `Data`.
/// * Case-insensitive path resolution via `CaseInsensitiveFileResolver`.
/// * Bundled runtimes (`ogv`, EasyRPG) are served from the *same* scheme and
///   host under `__runtime__/`, so `ogv.js` workers and `.wasm` fetches stay
///   same-origin on iPadOS 15.6.1.
final class RPGMSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "rpgm"
    static let host = "game"
    static let runtimePrefix = "__runtime__"

    private let gameRoot: URL
    private let resolver: CaseInsensitiveFileResolver
    private let runtimeRoot: URL?
    private let runtimeResolver: CaseInsensitiveFileResolver?
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(
        label: "com.faith.sparkrpgm.scheme",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let stateLock = NSLock()
    private var stoppedTasks = Set<ObjectIdentifier>()

    private static let chunkSize = 256 * 1024

    init(gameRoot: URL, bundle: Bundle = .main) {
        self.gameRoot = gameRoot.standardizedFileURL
        self.resolver = CaseInsensitiveFileResolver(root: self.gameRoot)
        self.runtimeRoot = bundle.url(forResource: "WebRuntime", withExtension: nil)
        if let runtimeRoot = self.runtimeRoot {
            self.runtimeResolver = CaseInsensitiveFileResolver(root: runtimeRoot)
        } else {
            self.runtimeResolver = nil
        }
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        stateLock.lock()
        stoppedTasks.remove(identifier)
        stateLock.unlock()

        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, identifier: identifier, status: 400, message: "Malformed request")
            return
        }

        let request = urlSchemeTask.request
        let method = (request.httpMethod ?? "GET").uppercased()
        if method != "GET" && method != "HEAD" {
            fail(urlSchemeTask, identifier: identifier, status: 405, message: "Method not allowed")
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            self.serve(urlSchemeTask, identifier: identifier, request: request, requestURL: requestURL)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        stateLock.lock()
        stoppedTasks.insert(identifier)
        stateLock.unlock()
    }

    // MARK: - Serving

    private func serve(
        _ task: WKURLSchemeTask,
        identifier: ObjectIdentifier,
        request: URLRequest,
        requestURL: URL
    ) {
        // EasyRPG's host page, game manifest and runtime manifest are generated
        // on demand instead of living in the app bundle.
        if let generated = generatedResource(for: requestURL) {
            respondGenerated(
                generated.data,
                contentType: generated.contentType,
                request: request,
                task: task,
                identifier: identifier
            )
            return
        }

        guard let fileURL = resolveFileURL(for: requestURL) else {
            fail(task, identifier: identifier, status: 404, message: "Not found")
            return
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            fail(task, identifier: identifier, status: 404, message: "Not found")
            return
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            fail(task, identifier: identifier, status: 500, message: "Unreadable file")
            return
        }

        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let contentType = MimeTypes.mimeType(for: fileURL)
        let isHEAD = (request.httpMethod ?? "GET").uppercased() == "HEAD"

        var headers: [String: String] = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": "*",
            "Cross-Origin-Resource-Policy": "cross-origin",
            "X-Spark-Served": "rpgm",
        ]
        headers["Content-Length"] = String(fileSize)

        // Byte ranges: only for media, and only for a single range.
        if !isHEAD,
           let rangeHeader = request.value(forHTTPHeaderField: "Range"),
           MimeTypes.supportsByteRanges(fileURL.pathExtension),
           let range = Self.parseRange(rangeHeader, total: fileSize) {

            let length = range.upperBound - range.lowerBound + 1
            headers["Content-Length"] = String(length)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"

            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                fail(task, identifier: identifier, status: 500, message: "Response error")
                return
            }

            guard send(response: response, to: task, identifier: identifier) else { return }
            stream(fileURL: fileURL, from: range.lowerBound, length: length, to: task, identifier: identifier)
            return
        }

        if !isHEAD, let rangeHeader = request.value(forHTTPHeaderField: "Range"),
           !MimeTypes.supportsByteRanges(fileURL.pathExtension) {
            // Ignore ranges for non-media: WebKit sometimes sends them for fonts.
            _ = rangeHeader
        }

        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            fail(task, identifier: identifier, status: 500, message: "Response error")
            return
        }

        guard send(response: response, to: task, identifier: identifier) else { return }

        if isHEAD || fileSize == 0 {
            finish(task, identifier: identifier)
            return
        }

        stream(fileURL: fileURL, from: 0, length: fileSize, to: task, identifier: identifier)
    }

    private func resolveFileURL(for requestURL: URL) -> URL? {
        // `URL.path` is percent-decoded, which is exactly what we want.
        var path = requestURL.path
        while path.hasPrefix("/") { path.removeFirst() }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // Drop the game folder component; this handler is scoped to one game.
        if let first = components.first, first != Self.runtimePrefix {
            components.removeFirst()
        }

        if components.isEmpty {
            components = ["index.html"]
        }

        if components[0] == Self.runtimePrefix {
            components.removeFirst()
            guard !components.isEmpty, let runtimeResolver = runtimeResolver else { return nil }
            return runtimeResolver.resolve(components.joined(separator: "/"))
        }

        // Directory requests (trailing slash or a folder) serve index.html.
        var relative = components.joined(separator: "/")
        if requestURL.path.hasSuffix("/") {
            relative += "/index.html"
        }

        if let url = resolver.resolve(relative) {
            if AppPaths.isDirectory(url) {
                return resolver.resolve(relative + "/index.html")
            }
            return url
        }

        // Last resort: treat it as a directory.
        return resolver.resolve(relative + "/index.html")
    }

    // MARK: - Generated EasyRPG resources

    private struct GeneratedResource {
        let data: Data
        let contentType: String
    }

    /// Recognises `.../__runtime__/easyrpg/host.html` and the two JSON
    /// manifests. Real bundle files with the same names lose to the generated
    /// versions, which keeps the runtime version-independent.
    private func generatedResource(for requestURL: URL) -> GeneratedResource? {
        let components = requestURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 3,
              components[components.count - 3] == Self.runtimePrefix,
              components[components.count - 2].lowercased() == "easyrpg" else {
            return nil
        }

        switch components[components.count - 1].lowercased() {
        case "host.html":
            return GeneratedResource(
                data: EasyRPGHostBuilder.hostHTML(),
                contentType: "text/html; charset=utf-8"
            )

        case "game-manifest.json":
            return GeneratedResource(
                data: EasyRPGHostBuilder.gameManifest(gameRoot: gameRoot),
                contentType: "application/json; charset=utf-8"
            )

        case "runtime-manifest.json":
            let easyrpg = runtimeRoot?.appendingPathComponent("easyrpg", isDirectory: true)
            return GeneratedResource(
                data: EasyRPGHostBuilder.runtimeManifest(runtimeRoot: easyrpg),
                contentType: "application/json; charset=utf-8"
            )

        default:
            return nil
        }
    }

    private func respondGenerated(
        _ data: Data,
        contentType: String,
        request: URLRequest,
        task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        let requestURL = request.url ?? URL(string: "rpgm://game/generated")!
        let isHEAD = (request.httpMethod ?? "GET").uppercased() == "HEAD"
        let headers: [String: String] = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Cross-Origin-Resource-Policy": "cross-origin",
            "X-Spark-Served": "rpgm-generated",
        ]

        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            fail(task, identifier: identifier, status: 500, message: "Response error")
            return
        }

        guard send(response: response, to: task, identifier: identifier) else { return }
        if !isHEAD, !data.isEmpty {
            guard send(data: data, to: task, identifier: identifier) else { return }
        }
        finish(task, identifier: identifier)
    }

    // MARK: - Streaming

    private func stream(
        fileURL: URL,
        from offset: Int64,
        length: Int64,
        to task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        guard length > 0 else {
            finish(task, identifier: identifier)
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            fail(task, identifier: identifier, status: 500, message: "Cannot open file")
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            fail(task, identifier: identifier, status: 500, message: "Cannot seek file")
            return
        }

        var remaining = length
        while remaining > 0 {
            if isStopped(identifier) { return }

            let toRead = Int(min(Int64(Self.chunkSize), remaining))
            let data: Data?
            do {
                data = try handle.read(upToCount: toRead)
            } catch {
                fail(task, identifier: identifier, status: 500, message: "Read failed")
                return
            }

            guard let chunk = data, !chunk.isEmpty else { break }
            remaining -= Int64(chunk.count)

            guard send(data: chunk, to: task, identifier: identifier) else { return }
        }

        finish(task, identifier: identifier)
    }

    // MARK: - Task plumbing (start/stop are serialised with a lock)

    private func isStopped(_ identifier: ObjectIdentifier) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedTasks.contains(identifier)
    }

    @discardableResult
    private func send(response: URLResponse, to task: WKURLSchemeTask, identifier: ObjectIdentifier) -> Bool {
        stateLock.lock()
        guard !stoppedTasks.contains(identifier) else {
            stateLock.unlock()
            return false
        }
        task.didReceive(response)
        stateLock.unlock()
        return true
    }

    @discardableResult
    private func send(data: Data, to task: WKURLSchemeTask, identifier: ObjectIdentifier) -> Bool {
        stateLock.lock()
        guard !stoppedTasks.contains(identifier) else {
            stateLock.unlock()
            return false
        }
        task.didReceive(data)
        stateLock.unlock()
        return true
    }

    private func finish(_ task: WKURLSchemeTask, identifier: ObjectIdentifier) {
        stateLock.lock()
        guard !stoppedTasks.contains(identifier) else {
            stateLock.unlock()
            return
        }
        stoppedTasks.insert(identifier)
        task.didFinish()
        stateLock.unlock()
    }

    private func fail(_ task: WKURLSchemeTask, identifier: ObjectIdentifier, status: Int, message: String) {
        let url = task.request.url ?? URL(string: "rpgm://game/error")!
        let body = Data("<html><body style=\"background:#0b0b12;color:#bbb;font:14px -apple-system;padding:24px\"><h3>\(message)</h3><p>\(url.lastPathComponent)</p></body></html>".utf8)
        var headers: [String: String] = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(body.count),
        ]
        if status == 416 {
            headers["Content-Range"] = "bytes */0"
        }

        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            stateLock.lock()
            if !stoppedTasks.contains(identifier) {
                stoppedTasks.insert(identifier)
                task.didFailWithError(NSError(domain: "SparkRPGM", code: status))
            }
            stateLock.unlock()
            return
        }

        stateLock.lock()
        guard !stoppedTasks.contains(identifier) else {
            stateLock.unlock()
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        stoppedTasks.insert(identifier)
        task.didFinish()
        stateLock.unlock()
    }

    // MARK: - Range parsing

    /// Parses `bytes=start-end`, `bytes=start-`, `bytes=-suffix`.
    static func parseRange(_ header: String, total: Int64) -> ClosedRange<Int64>? {
        guard total > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }

        var spec = String(trimmed.dropFirst("bytes=".count))
        if spec.contains(",") {
            spec = String(spec.split(separator: ",")[0])
        }
        spec = spec.trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }

        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // Suffix range: last N bytes.
            guard let suffix = Int64(endText), suffix > 0 else { return nil }
            let length = min(suffix, total)
            return (total - length)...(total - 1)
        }

        guard let start = Int64(startText), start >= 0, start < total else { return nil }
        if endText.isEmpty {
            return start...(total - 1)
        }
        guard let end = Int64(endText), end >= start else { return nil }
        return start...min(end, total - 1)
    }
}
