import Foundation
import WebKit
import UIKit

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

    private(set) var webView: WKWebView!
    private let resolver: CaseInsensitiveFileResolver
    private var didSetup = false
    private var lastReadyAt = Date.distantPast
    /// 1x / 2x / 3x requested from the in-game top bar. Kept here so a reload
    /// or a web-process restart re-applies it to the fresh page.
    private var speedMultiplier = 1

    init(game: Game, entry: Entry = .gameIndex) {
        self.game = game
        self.entry = entry
        self.context = GameWebContext(game: game)
        self.resolver = CaseInsensitiveFileResolver(root: game.rootURL)
        self.schemeHandler = RPGMSchemeHandler(gameRoot: game.rootURL)
        super.init()
        bridge.session = self
        AppPaths.ensureSaveFolder(forGame: game.folderName)
    }

    /// The URL loaded into the main frame.
    var entryURL: URL {
        switch entry {
        case .gameIndex:
            return context.entryURL
        case .easyRPGHost:
            return context.easyRPGHostURL
        }
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
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = configuration.userContentController
        controller.add(bridge, name: "sparkLog")
        controller.add(bridge, name: "sparkReady")
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
        loadGame()
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
        var request = URLRequest(url: entryURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    func reload() {
        resolver.invalidate()
        webView?.reload()
        isLoading = true
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
        webView?.stopLoading()
        let controller = webView?.configuration.userContentController
        for name in ["sparkLog", "sparkReady", "sparkContextLost", "saveBridge", "fsBridge"] {
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

        case "sparkReady":
            if Date().timeIntervalSince(lastReadyAt) > 0.3 {
                lastReadyAt = Date()
                isLoading = false
                if speedMultiplier > 1 { applySpeed() }
            }

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
            } catch {
                Log.error("Save write failed for \(fileName)", error: error)
            }

        case "read":
            guard let bytes = try? Data(contentsOf: fileURL) else { return }
            respond(saveData: bytes.base64EncodedString(), name: fileName, webView: webView)

        case "remove", "delete":
            try? fileManager.removeItem(at: fileURL)

        case "list":
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            let payload = names.filter { !$0.hasPrefix(".") }
            respond(saveNames: payload, webView: webView)

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
        isLoading = false
        if speedMultiplier > 1 { applySpeed() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadError = error.localizedDescription
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadError = error.localizedDescription
        isLoading = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web process can be killed under memory pressure on 3 GB devices.
        // A gentle reload restores the game instead of showing a dead canvas.
        Log.app("Web content process terminated; reloading \(game.folderName)")
        isLoading = true
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
        case "rpgm", "about":
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
