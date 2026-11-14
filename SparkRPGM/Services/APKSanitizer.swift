import Foundation

/// Removes Android/Cordova wrapper hooks from an APK's `index.html`.
///
/// RPG Maker MV/MZ games packaged for Android boot inside a Cordova WebView.
/// Those `<script src="cordova.js">` tags 404 on iOS and can hijack audio
/// initialisation, so they are stripped before the game is moved into
/// `Documents/games`.
enum APKSanitizer {

    private static let scriptTagPattern =
        #"<script\b[^>]*\bsrc\s*=\s*(?:"[^"]*cordova(?:_plugins)?\.js[^"]*"|'[^']*cordova(?:_plugins)?\.js[^']*')[^>]*>\s*</script\s*>"#

    private static let looseCordovaPattern =
        #"<script\b[^>]*cordova(?:_plugins)?\.js[^>]*>\s*</script\s*>"#

    /// Rewrites every `index.html` / `www/index.html` found under `root`.
    @discardableResult
    static func sanitize(root: URL) -> Int {
        let resolver = CaseInsensitiveFileResolver(root: root)
        guard let indexURL = resolver.resolve("index.html") else { return 0 }
        return sanitize(indexFile: indexURL) ? 1 : 0
    }

    @discardableResult
    static func sanitize(indexFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: indexFile), !data.isEmpty else { return false }

        var encoding: String.Encoding = .utf8
        var text = String(data: data, encoding: encoding)
        if text == nil {
            encoding = .isoLatin1
            text = String(data: data, encoding: encoding)
        }
        guard var html = text else { return false }

        let original = html
        for pattern in [scriptTagPattern, looseCordovaPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            html = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
        }

        // Drop Cordova's own bootstrap block if the wrapper inlined it.
        if let regex = try? NSRegularExpression(
            pattern: #"document\.addEventListener\s*\(\s*['"]deviceready['"][\s\S]{0,600}?\}\s*\)\s*;?"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            html = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
        }

        guard html != original else { return false }
        guard let encoded = html.data(using: encoding) else { return false }

        do {
            try encoded.write(to: indexFile, options: .atomic)
            Log.app("Sanitized APK index.html at \(indexFile.path)")
            return true
        } catch {
            Log.error("Failed to sanitize index.html", error: error)
            return false
        }
    }
}
