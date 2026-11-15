import Foundation
import WebKit
import UIKit
import SwiftUI

/// Owns one WKWebView plus its scheme handler and message bridge.
final class GameSession: NSObject, ObservableObject {

    /// Which document the session boots.
    ///
    /// MV/MZ/HTML5 load the game's own `index.html`. EasyRPG titles load a
    /// generated host page that mounts the wasm runtime and copies the game
    /// into its virtual filesystem.
    enum Entry {
        case gameIndex
        case easyRPGHost
    }

    let game: Game
    let entry: Entry
    let context: GameWebContext
    let schemeHandler: RPGMSchemeHandler
    let bridge = WebBridge()

    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var contextLost = false
    /// Active boot step reported live by spark-bootstrap.
    @Published private(set) var bootStage: String?
    /// Last JavaScript exception or failed script reported by the bootstrap.
    @Published private(set) var bootDiagnostic: String?
    /// Files the scheme handler could not resolve, newest last (capped).
    @Published private(set) var missingResources: [String] = []
    /// Set by the watchdog when the game has not signalled readiness in time.
    @Published private(set) var didStall = false
    /// Whether the user dismissed the top diagnostic banner. Reset automatically on incoming updates.
    @Published private(set) var isDiagnosticDismissed = false

    private(set) var webView: WKWebView!
    private let resolver: CaseInsensitiveFileResolver
    private var didSetup = false
    private var lastReadyAt = Date.distantPast
    private var stallWorkItem: DispatchWorkItem?
    private var loadingSafetyWorkItem: DispatchWorkItem?
    /// `true` once the document finished, the injected `load` listener fired,
    /// or the engine reported a running scene. Used by the stall watchdog so a
    /// healthy game is never declared dead.
    private var sawReadySignal = false
    /// 1x / 2x / 3x requested from the in-game top bar. Kept here so a reload
    /// or a web-process restart re-applies it to the fresh page.
    private var speedMultiplier = 1

    /// Shown when the native spinner has to step aside before the engine says
    /// it is alive. The banner stays dismissible, so the player is never stuck
    /// on a grey screen.
    static let slowBootNotice = "The game is still starting after 12 seconds. It may be waiting on a missing file or a slow WebAssembly compile."

    static let missingEngineNotice = "The page loaded but no RPG Maker engine reported a running scene. A script may have failed to load."

    init(game: Game, entry: Entry = .gameIndex) {
        self.game = game
        self.entry = entry
        self.context = GameWebContext(game: game)
        self.resolver = CaseInsensitiveFileResolver(root: game.rootURL)
        self.schemeHandler = RPGMSchemeHandler(gameRoot: game.rootURL, entryPath: game.entryPath)
        super.init()
        bridge.session = self
        schemeHandler.onMissingResource = { [weak self] path in
            self?.recordMissingResource(path)
        }
        AppPaths.ensureSaveFolder(forGame: game.folderName)
    }

    /// Resolves the actual index.html on disk for native file:// loading.
    func resolveIndexURL() -> URL {
        let fileManager = FileManager.default
        let candidates: [URL] = [
            game.entryFileURL,
            game.engineRootURL.appendingPathComponent("index.html"),
            game.rootURL.appendingPathComponent("index.html"),
            game.rootURL.appendingPathComponent("www/index.html"),
        ]
        for url in candidates {
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return game.entryFileURL
    }

    /// The target URL loaded into the main frame.
    var targetURL: URL {
        switch entry {
        case .gameIndex:
            return resolveIndexURL()
        case .easyRPGHost:
            return context.easyRPGHostURL
        }
    }

    /// The URL loaded into the main frame.
    var entryURL: URL {
        targetURL
    }

    // MARK: - Setup

    func makeWebViewIfNeeded() -> WKWebView {
        if let webView = webView { return webView }
        let configuration = WKWebViewConfiguration()

        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: RPGMSchemeHandler.scheme)
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.javaScriptEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Enable local file access and universal access for file:// XHR/fetch
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        sparkSetIfAvailable(configuration.preferences, key: "allowFileAccessFromFileURLs", value: true)
        sparkSetIfAvailable(configuration, key: "allowUniversalAccessFromFileURLs", value: true)
        sparkSetIfAvailable(configuration.preferences, key: "allowUniversalAccessFromFileURLs", value: true)

        let controller = configuration.userContentController
        controller.add(bridge, name: "sparkLog")
        controller.add(bridge, name: "sparkReady")
        controller.add(bridge, name: "gameReady")
        controller.add(bridge, name: "bootStage")
        controller.add(bridge, name: "sparkError")
        controller.add(bridge, name: "sparkContextLost")
        controller.add(bridge, name: "saveBridge")
        controller.add(bridge, name: "fsBridge")

        installUserScripts(into: controller)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.isMultipleTouchEnabled = true
        if #available(iOS 15.0, *) {
            view.underPageBackgroundColor = .black
        }

        webView = view
        didSetup = true
        return view
    }

    private func installUserScripts(into controller: WKUserContentController) {
        let lowMemory = ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
        let configScript = context.configurationScript(lowMemory: lowMemory)
        controller.addUserScript(WKUserScript(
            source: configScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        for name in RuntimeScripts.orderedNames {
            guard let source = RuntimeScripts.guardedSource(named: name) else { continue }
            controller.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        let css = """
        ;(function(){
        try {
        var style = document.createElement('style');
        style.id = 'sparkrpgm-base-style';
        style.textContent = 'html,body{-webkit-touch-callout:none;-webkit-user-select:none;overscroll-behavior:none;background:#000;} input,textarea{-webkit-user-select:text;}';
        (document.head || document.documentElement).appendChild(style);
        } catch (e) { console.error('[SparkRPGM] css injection failed', e); }
        })();
        """
        controller.addUserScript(WKUserScript(
            source: css,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    // MARK: - Loading

    func loadGame() {
        guard let webView = webView else { return }
        isLoading = true
        loadError = nil
        contextLost = false
        bootDiagnostic = nil
        isDiagnosticDismissed = false
        missingResources = []
        didStall = false
        sawReadySignal = false
        armStallWatchdog()
        armLoadingSafetyGuard()

        switch entry {
        case .easyRPGHost:
            var request = URLRequest(url: targetURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
        case .gameIndex:
            let indexURL = resolveIndexURL()
            webView.loadFileURL(indexURL, allowingReadAccessTo: game.rootURL)
        }
    }

    func reload() {
        resolver.invalidate()
        isLoading = true
        loadError = nil
        bootDiagnostic = nil
        isDiagnosticDismissed = false
        missingResources = []
        didStall = false
        sawReadySignal = false
        armStallWatchdog()
        armLoadingSafetyGuard()
        webView?.reload()
    }

    private func armStallWatchdog() {
        stallWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.sawReadySignal, self.loadError == nil else { return }
            // A concrete failure (missing script, data file, wasm module, or a
            // JavaScript exception) deserves the actionable Retry / Close
            // overlay. A slow but healthy boot stays a dismissible banner so
            // the game canvas remains visible.
            if let diagnostic = self.bootDiagnostic, diagnostic != Self.slowBootNotice {
                self.didStall = true
            } else if self.bootDiagnostic == nil {
                self.bootDiagnostic = Self.slowBootNotice
            }
        }
        stallWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
    }

    /// The native spinner must never trap the player. If nothing has cleared it
    /// after 12 seconds it steps aside and hands the screen to the diagnostics
    /// banner, whatever the engine is doing.
    private func armLoadingSafetyGuard() {
        loadingSafetyWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isLoading, self.loadError == nil else { return }
            self.markLoaded()
            if self.bootDiagnostic == nil {
                self.bootDiagnostic = Self.slowBootNotice
            }
        }
        loadingSafetyWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    func markLoaded() {
        loadingSafetyWorkItem?.cancel()
        loadingSafetyWorkItem = nil
        guard isLoading else { return }
        withAnimation(.easeOut(duration: 0.35)) {
            isLoading = false
        }
        if speedMultiplier > 1 { applySpeed() }
    }

    /// Any readiness path (document finish, injected `load` event, running
    /// `SceneManager`) lands here so the spinner, watchdog and error overlay
    /// agree on one state.
    private func markGameReady() {
        sawReadySignal = true
        didStall = false
        if bootDiagnostic == Self.slowBootNotice || bootDiagnostic == Self.missingEngineNotice {
            bootDiagnostic = nil
        }
        markLoaded()
    }

    /// Clears the on-screen diagnostic banner without touching the running game.
    func dismissDiagnostic() {
        isDiagnosticDismissed = true
        didStall = false
    }

    private func clearStallWatchdog() {
        stallWorkItem?.cancel()
        stallWorkItem = nil
    }

    private static let fatalResourceExtensions: Set<String> = ["js", "mjs", "html", "htm", "json", "wasm"]

    private func recordMissingResource(_ path: String) {
        if !missingResources.contains(path) {
            if missingResources.count >= 12 { missingResources.removeFirst() }
            missingResources.append(path)
        }
        // A missing sound or sprite is survivable; a missing script, data file
        // or wasm module is what actually stops a boot. Only the latter raises
        // the error state, while the full list still feeds the stall report.
        let fileExtension = (path as NSString).pathExtension.lowercased()
        if bootDiagnostic == nil, Self.fatalResourceExtensions.contains(fileExtension) {
            bootDiagnostic = "Missing file: \(path)"
        }
    }

    /// Sets the in-game speed multiplier (clamped to 1–3).
    ///
    /// The JS shim multiplies `SceneManager.updateScene` for MV/MZ or the
    /// `requestAnimationFrame` loop for EasyRPG/HTML5. Re-applied automatically
    /// after a reload, a web-process restart, and the first `sparkReady` ping.
    func setSpeed(_ multiplier: Int) {
        speedMultiplier = max(1, min(3, multiplier))
        applySpeed()
    }

    private func applySpeed() {
        let value = speedMultiplier
        evaluate("""
        if (window.__sparkSetSpeed) {
          try { window.__sparkSetSpeed(\(value)); }
          catch (e) { console.error('[SparkRPGM] setSpeed failed', e); }
        }
        """)
    }

    func stop() {
        clearStallWatchdog()
        loadingSafetyWorkItem?.cancel()
        loadingSafetyWorkItem = nil
        webView?.stopLoading()
        let controller = webView?.configuration.userContentController
        for name in ["sparkLog", "sparkReady", "gameReady", "sparkError", "sparkContextLost", "saveBridge", "fsBridge"] {
            controller?.removeScriptMessageHandler(forName: name)
        }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        didSetup = false
    }

    // MARK: - Input

    /// Sends a synthetic key event through `window.__sparkKey`.
    ///
    /// `key` is used for both `KeyboardEvent.key` and `.code`; RPG Maker only
    /// consumes the numeric `keyCode`, which we force on the event.
    func sendKey(type: String, key: String, keyCode: Int, button: String? = nil) {
        let keyLiteral = Self.jsString(key)
        let buttonLiteral = button.map { Self.jsString($0) } ?? "null"
        let script = """
        if (window.__sparkKey) {
          try { window.__sparkKey('\(type)', \(keyLiteral), \(keyCode), \(buttonLiteral)); }
          catch (e) { console.error('[SparkRPGM] key dispatch failed', e); }
        }
        """
        evaluate(script)
    }

    func evaluate(_ script: String) {
        let run = { [weak self] in
            self?.webView?.evaluateJavaScript(script) { _, error in
                if let error = error {
                    Log.web("evaluateJavaScript error: \(error.localizedDescription)")
                }
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async { _ = run() }
        }
    }

    static func jsString(_ value: String) -> String {
        var escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        escaped = "'" + escaped + "'"
        return escaped
    }

    // MARK: - Message handling

    func handle(message: WKScriptMessage) {
        switch message.name {
        case "sparkLog":
            if let text = message.body as? String {
                Log.web(text)
            } else {
                Log.web(String(describing: message.body))
            }

        case "sparkReady", "gameReady":
            let payload = message.body as? [String: Any]
            guard Date().timeIntervalSince(lastReadyAt) > 0.3 else { return }
            lastReadyAt = Date()
            markGameReady()
            markLoaded()
            if let hasEngine = payload?["hasEngine"] as? Bool,
               hasEngine == false,
               bootDiagnostic == nil,
               game.engine == .rpgMakerMZ || game.engine == .rpgMakerMV {
                bootDiagnostic = Self.missingEngineNotice
            }

        case "bootStage":
            if let dict = message.body as? [String: Any] {
                let stage = dict["stage"] as? String ?? ""
                if !stage.isEmpty {
                    self.bootStage = stage
                }
                let isFinished = dict["isFinished"] as? Bool ?? false
                if isFinished || stage.contains("Title screen") || stage.contains("Scene_Title") {
                    markGameReady()
                    markLoaded()
                }
            } else if let stage = message.body as? String, !stage.isEmpty {
                self.bootStage = stage
                if stage.contains("Title screen") || stage.contains("Scene_Title") {
                    markGameReady()
                    markLoaded()
                }
            }

        case "sparkError":
            handleSparkError(message.body)

        case "sparkContextLost":
            contextLost = true
            isLoading = false

        case "saveBridge":
            guard let body = message.body as? [String: Any], let webView = message.webView else { return }
            handleSaveBridge(body, webView: webView)

        case "fsBridge":
            guard let body = message.body as? [String: Any], let webView = message.webView else { return }
            handleFSBridge(body, webView: webView)

        default:
            break
        }
    }

    // MARK: - Boot diagnostics

    private func handleSparkError(_ body: Any) {
        guard let payload = body as? [String: Any] else {
            Log.web(String(describing: body))
            return
        }

        let kind = (payload["kind"] as? String)?.lowercased() ?? "error"
        let message = payload["message"] as? String ?? "Unknown error"
        let source = payload["source"] as? String ?? ""
        let line = payload["line"] as? Int ?? 0

        if kind == "info" {
            Log.web("boot: \(message)")
            return
        }

        var text = message
        if !source.isEmpty {
            text += " (\(source)\(line > 0 ? ":\(line)" : ""))"
        }
        Log.error("Game boot \(kind): \(text)")

        // Always surface live diagnostic and stall updates, un-dismissing the top banner automatically
        bootDiagnostic = text
        isDiagnosticDismissed = false
    }

    // MARK: - Native disk save bridge

    private func handleSaveBridge(_ body: [String: Any], webView: WKWebView) {
        let action = (body["action"] as? String)?.lowercased() ?? ""
        let rawName = body["name"] as? String ?? ""
        guard let fileName = Self.safeSaveFileName(rawName) else {
            Log.web("Rejected save file name: \(rawName)")
            return
        }

        let folder = AppPaths.ensureSaveFolder(forGame: game.folderName)
        let fileURL = folder.appendingPathComponent(fileName)
        let sparkFolder = game.rootURL.appendingPathComponent(".spark/saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: sparkFolder, withIntermediateDirectories: true, attributes: nil)
        let sparkFileURL = sparkFolder.appendingPathComponent(fileName)
        let fileManager = FileManager.default

        switch action {
        case "save", "write":
            let payload = body["data"] as? String ?? ""
            let encoding = (body["encoding"] as? String)?.lowercased()
            let data: Data?
            if encoding == "base64" {
                data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            } else {
                data = Data(payload.utf8)
            }
            guard let bytes = data else {
                Log.web("Rejected save payload for \(fileName): invalid base64")
                return
            }
            do {
                try bytes.write(to: fileURL, options: .atomic)
                try? bytes.write(to: sparkFileURL, options: .atomic)
            } catch {
                Log.error("Save write failed for \(fileName)", error: error)
            }

        case "read":
            let bytes = (try? Data(contentsOf: fileURL)) ?? (try? Data(contentsOf: sparkFileURL))
            guard let payloadBytes = bytes else { return }
            respond(saveData: payloadBytes.base64EncodedString(), name: fileName, webView: webView)

        case "remove", "delete":
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: sparkFileURL)

        case "list":
            let docNames = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            let sparkNames = (try? fileManager.contentsOfDirectory(atPath: sparkFolder.path)) ?? []
            let allNames = Set(docNames + sparkNames).filter { !$0.hasPrefix(".") }
            respond(saveNames: Array(allNames), webView: webView)

        default:
            break
        }
    }

    private func respond(saveNames: [String], webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: saveNames),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__sparkSaveListResult && window.__sparkSaveListResult(\(json));", completionHandler: nil)
    }

    private func respond(saveData: String, name: String, webView: WKWebView) {
        let nameLiteral = Self.jsString(name)
        let dataLiteral = Self.jsString(saveData)
        webView.evaluateJavaScript(
            "window.__sparkSaveReadResult && window.__sparkSaveReadResult(\(nameLiteral), \(dataLiteral));",
            completionHandler: nil
        )
    }

    static func safeSaveFileName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        if trimmed.hasPrefix(".") { return nil }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..") { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    // MARK: - nw.js filesystem bridge

    private func handleFSBridge(_ body: [String: Any], webView: WKWebView) {
        let action = (body["action"] as? String)?.lowercased() ?? ""
        let requestID = body["id"] as? Int ?? -1
        let rawPath = body["path"] as? String ?? ""
        let relative = Self.relativeFSPath(rawPath, gameFolder: game.folderName)

        guard let relative = relative else {
            sendFSResponse(["ok": false, "error": "invalid path"], id: requestID, webView: webView)
            return
        }

        let fm = FileManager.default
        let overlayRoot = AppPaths.nwfsRoot.appendingPathComponent(game.folderName, isDirectory: true)
        let overlayURL = overlayRoot.appendingPathComponent(relative)
        let readURL = resolver.resolve(relative)

        switch action {
        case "read":
            // Writes shadow the read-only game folder.
            if fm.fileExists(atPath: overlayURL.path), let data = try? Data(contentsOf: overlayURL) {
                sendFSResponse(["ok": true, "data": String(data: data, encoding: .utf8) ?? ""], id: requestID, webView: webView)
                return
            }
            guard let url = readURL, let data = try? Data(contentsOf: url) else {
                sendFSResponse(["ok": false, "error": "ENOENT"], id: requestID, webView: webView)
                return
            }
            sendFSResponse(["ok": true, "data": String(data: data, encoding: .utf8) ?? ""], id: requestID, webView: webView)

        case "write", "append":
            let text = body["data"] as? String ?? ""
            do {
                try fm.createDirectory(at: overlayURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                if action == "append", let handle = try? FileHandle(forWritingTo: overlayURL) {
                    handle.seekToEndOfFile()
                    handle.write(Data(text.utf8))
                    try? handle.close()
                } else {
                    try Data(text.utf8).write(to: overlayURL, options: .atomic)
                }
                sendFSResponse(["ok": true], id: requestID, webView: webView)
            } catch {
                sendFSResponse(["ok": false, "error": error.localizedDescription], id: requestID, webView: webView)
            }

        case "exists":
            let exists = fm.fileExists(atPath: overlayURL.path) || (readURL != nil)
            sendFSResponse(["ok": true, "data": exists], id: requestID, webView: webView)

        case "stat":
            let url = fm.fileExists(atPath: overlayURL.path) ? overlayURL : readURL
            guard let url = url,
                  let attributes = try? fm.attributesOfItem(atPath: url.path) else {
                sendFSResponse(["ok": false, "error": "ENOENT"], id: requestID, webView: webView)
                return
            }
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            sendFSResponse(["ok": true, "data": ["isDirectory": isDirectory, "size": size]], id: requestID, webView: webView)

        case "list":
            let target = fm.fileExists(atPath: overlayURL.path) ? overlayURL : readURL
            guard let target = target,
                  let names = try? fm.contentsOfDirectory(atPath: target.path) else {
                sendFSResponse(["ok": false, "error": "ENOENT"], id: requestID, webView: webView)
                return
            }
            sendFSResponse(["ok": true, "data": names.filter { !$0.hasPrefix(".") }], id: requestID, webView: webView)

        case "mkdir":
            do {
                try fm.createDirectory(at: overlayURL, withIntermediateDirectories: true, attributes: nil)
                sendFSResponse(["ok": true], id: requestID, webView: webView)
            } catch {
                sendFSResponse(["ok": false, "error": error.localizedDescription], id: requestID, webView: webView)
            }

        case "unlink":
            try? fm.removeItem(at: overlayURL)
            sendFSResponse(["ok": true], id: requestID, webView: webView)

        case "rename":
            let toPath = body["to"] as? String ?? ""
            guard let toRelative = Self.relativeFSPath(toPath, gameFolder: game.folderName) else {
                sendFSResponse(["ok": false, "error": "invalid path"], id: requestID, webView: webView)
                return
            }
            let destination = overlayRoot.appendingPathComponent(toRelative)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
                try fm.moveItem(at: overlayURL, to: destination)
                sendFSResponse(["ok": true], id: requestID, webView: webView)
            } catch {
                sendFSResponse(["ok": false, "error": error.localizedDescription], id: requestID, webView: webView)
            }

        default:
            sendFSResponse(["ok": false, "error": "unsupported action"], id: requestID, webView: webView)
        }
    }

    private func sendFSResponse(_ payload: [String: Any], id: Int, webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__sparkNativeCallback && window.__sparkNativeCallback('fs', \(id), \(json));", completionHandler: nil)
    }

    static func relativeFSPath(_ raw: String, gameFolder: String) -> String? {
        var value = raw.replacingOccurrences(of: "\\", with: "/")
        value = value.removingPercentEncoding ?? value
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }

        // Strip Windows drive letters and the virtual cwd prefix.
        if value.count >= 2 {
            let index = value.index(value.startIndex, offsetBy: 1)
            if value[index] == ":" {
                value.removeFirst(2)
                while value.hasPrefix("/") { value.removeFirst() }
            }
        }
        if value.hasPrefix(gameFolder + "/") {
            value.removeFirst(gameFolder.count + 1)
        }

        let normalised = CaseInsensitiveFileResolver.normalise(value)
        guard !normalised.isEmpty, !CaseInsensitiveFileResolver.containsTraversal(normalised) else { return nil }
        return normalised
    }
}

// MARK: - WKNavigationDelegate

extension GameSession: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if speedMultiplier > 1 { applySpeed() }
        // Dismiss the native loading overlay as soon as navigation completes
        markLoaded()
        // Ensure that within 1.5s max fade-out the live canvas is completely visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.markLoaded()
        }
        scheduleMissingEngineCheck()
    }

    /// A finished document that never produced an engine object is the exact
    /// shape of the "Starting RPG Maker MZ" hang. Say so instead of leaving a
    /// black canvas with no explanation.
    private func scheduleMissingEngineCheck() {
        guard entry == .gameIndex, game.engine.isWebBased else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.webView != nil else { return }
            guard !self.sawReadySignal, self.loadError == nil, self.bootDiagnostic == nil else { return }
            self.bootDiagnostic = Self.missingEngineNotice
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        let msg = "Navigation failed: \(error.localizedDescription)"
        Log.error(msg)
        bootDiagnostic = msg
        markLoaded()
        clearStallWatchdog()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        let msg = "Could not open index.html: \(error.localizedDescription)"
        Log.error(msg)
        bootDiagnostic = msg
        markLoaded()
        clearStallWatchdog()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web process can be killed under memory pressure on 3 GB devices.
        // A gentle reload restores the game instead of showing a dead canvas.
        Log.app("Web content process terminated; reloading \(game.folderName)")
        isLoading = true
        bootDiagnostic = nil
        isDiagnosticDismissed = false
        missingResources = []
        didStall = false
        sawReadySignal = false
        armStallWatchdog()
        armLoadingSafetyGuard()
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        switch url.scheme?.lowercased() {
        case "rpgm", "file", "about":
            decisionHandler(.allow)
        case "http", "https":
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        case "blob", "data":
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        default:
            decisionHandler(.cancel)
        }
    }
}

// MARK: - WKUIDelegate

extension GameSession: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        presentAlert(title: game.title, message: message) {
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: game.title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter()?.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: game.title, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presenter()?.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return nil
    }

    private func presentAlert(title: String, message: String, completion: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        presenter()?.present(alert, animated: true)
    }

    private func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

/// Keeps the strong reference out of the WKUserContentController -> session
/// cycle. The controller retains the bridge; the bridge only weakly holds the
/// session.
final class WebBridge: NSObject, WKScriptMessageHandler {

    weak var session: GameSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.handle(message: message)
    }
}

/// Applies a KVC key only when the object exposes the matching setter, so a
/// private WebKit key can never raise an Objective-C exception.
private func sparkSetIfAvailable(_ object: NSObject, key: String, value: Any) {
    let suffix = key.prefix(1).uppercased() + key.dropFirst()
    let selectors = [
        NSSelectorFromString("set\(suffix):"),
        NSSelectorFromString("_set\(suffix):")
    ]
    if selectors.contains(where: { object.responds(to: $0) }) {
        object.setValue(value, forKey: key)
    }
}
