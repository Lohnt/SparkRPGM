import Foundation

/// A file handed to the app by `UIDocumentPickerViewController` (or by
/// "Open in SparkRPGM").
///
/// The security scope is claimed as soon as the document picker returns and is
/// held for as long as this object is alive. `ImportCoordinator` keeps the
/// token in its queue until extraction finishes, so a 15 GB archive stays
/// readable for the whole job without ever being copied into `tmp`.
final class PickedDocument {

    let url: URL

    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        self.didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
