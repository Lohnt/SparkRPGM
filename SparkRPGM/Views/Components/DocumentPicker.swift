import UIKit
import UniformTypeIdentifiers

/// Presents `UIDocumentPickerViewController` directly from the key window.
///
/// Presenting the picker inside a SwiftUI `.sheet` was unreliable on iPadOS 15
/// — the delegate could return without the callback ever reaching SwiftUI. A
/// plain UIKit presentation from the top-most controller, with the delegate
/// kept on a long-lived singleton, makes the callback deterministic.
///
/// `asCopy: false` is essential: it hands back a security-scoped URL instead of
/// duplicating a multi-gigabyte APK into the app's temporary directory.
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {

    static let shared = DocumentPickerPresenter()

    private var completion: (([PickedDocument]) -> Void)?

    private override init() {
        super.init()
    }

    func present(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onPicked: @escaping ([PickedDocument]) -> Void
    ) {
        guard let presenter = ViewPresenter.topViewController() else { return }

        completion = onPicked

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .formSheet
        picker.modalTransitionStyle = .coverVertical

        presenter.present(picker, animated: true, completion: nil)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        let documents = urls.map(PickedDocument.init(url:))
        deliver(documents, dismissing: controller)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliver([], dismissing: controller)
    }

    private func deliver(_ documents: [PickedDocument], dismissing controller: UIViewController) {
        let callback = completion
        completion = nil
        controller.dismiss(animated: true) {
            DispatchQueue.main.async {
                callback?(documents)
            }
        }
    }

    // MARK: - Presentation helpers

}

/// Small helper shared by the UIKit pickers.
enum ViewPresenter {

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let keyWindow = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        return topmost(from: keyWindow?.rootViewController)
    }

    private static func topmost(from controller: UIViewController?) -> UIViewController? {
        guard let controller = controller else { return nil }

        if let presented = controller.presentedViewController {
            return topmost(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return topmost(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topmost(from: tab.selectedViewController)
        }
        return controller
    }
}

enum DocumentPickerTypes {

    /// Every file kind: `.zip`, `.apk`, `.7z`, `.rar` and loose folders.
    static var archives: [UTType] { [.item] }

    static var images: [UTType] { [.image] }
}
