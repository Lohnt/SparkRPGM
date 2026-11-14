import Foundation

/// Loads the JavaScript shims that are injected at `.atDocumentStart`.
///
/// The files live in `Resources/JS` and are copied flat into the app bundle by
/// Xcode. Each one is written defensively so that a failure in one shim can
/// never stop the game itself from booting.
enum RuntimeScripts {

    static let orderedNames = [
        "spark-core",
        "spark-nw",
        "spark-audio",
        "spark-storage",
        "spark-input",
        "spark-speed",
    ]

    static func source(named name: String, bundle: Bundle = .main) -> String? {
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "js"),
            bundle.url(forResource: name, withExtension: "js", subdirectory: "JS"),
            bundle.url(forResource: name, withExtension: "js", subdirectory: "Resources/JS"),
        ]
        for candidate in candidates {
            if let url = candidate, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// Wraps a shim in try/catch so a syntax or runtime problem degrades to a
    /// console error instead of breaking the game's boot sequence.
    static func guardedSource(named name: String, bundle: Bundle = .main) -> String? {
        guard let raw = source(named: name, bundle: bundle) else {
            Log.error("Missing JS runtime file: \(name).js")
            return nil
        }
        let safeName = name.replacingOccurrences(of: "'", with: "")
        return """
        ;(function(){
        try {
        \(raw)
        } catch (sparkError) {
            console.error('[SparkRPGM] shim \(safeName) failed:', sparkError && sparkError.stack ? sparkError.stack : sparkError);
        }
        })();
        """
    }

    /// Concatenated fallback (used when a specific script cannot be found).
    static func allGuardedSources(bundle: Bundle = .main) -> String {
        orderedNames.compactMap { guardedSource(named: $0, bundle: bundle) }.joined(separator: "\n")
    }
}
