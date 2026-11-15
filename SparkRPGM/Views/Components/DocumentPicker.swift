import UIKit
import UniformTypeIdentifiers

/// Presents `UIDocumentPickerViewController` directly from the key window.
///
/// Presenting the picker inside a SwiftUI `.sheet` was unreliable on iPadOS 15,
/// where the delegate could return without the callback ever reaching SwiftUI.
/// A plain UIKit presentation from the top-most controller, with the picker and
/// its delegate kept alive by this singleton, makes the callback deterministic.
///
/// `asCopy: true` is deliberate. iPadOS 15 file providers (Downloads, iCloud
/// Drive, Google Drive, OneDrive) frequently deny direct reads of `.apk` files
/// returned with `asCopy: false`, which made imports appear to do nothing. The
/// picker now hands back a temporary copy owned by the app, and
/// `PickedDocument.prepare()` still falls back to a coordinated copy for URLs
/// that arrive from "Open in SparkRPGM".
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {

    static let shared = DocumentPickerPresenter()

    private var completion: (([PickedDocument]) -> Void)?

    /// Retained until `didPickDocumentsAt` / `documentPickerWasCancelled`.
    /// Without this the picker can deallocate on iPadOS 15 before the callback.
    private var activePicker: UIDocumentPickerViewController?

    private override init() {
        super.init()
    }

    func present(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onPicked: @escaping ([PickedDocument]) -> Void,
        onFailure: ((String) -> Void)? = nil
    ) {
        present(
            contentTypes: contentTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            onPicked: onPicked,
            onFailure: onFailure,
            retries: 4
        )
    }

    private func present(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onPicked: @escaping ([PickedDocument]) -> Void,
        onFailure: ((String) -> Void)?,
        retries: Int
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.present(
                    contentTypes: contentTypes,
                    allowsMultipleSelection: allowsMultipleSelection,
                    onPicked: onPicked,
                    onFailure: onFailure,
                    retries: retries
                )
            }
            return
        }

        // A stale picker (swiped away without a delegate callback) must not
        // block every later import.
        if let existing = activePicker,
           existing.presentingViewController != nil || existing.isBeingPresented {
            onFailure?("Finish the current file picker before starting another import.")
            return
        }
        activePicker = nil

        guard let presenter = ViewPresenter.topViewController() else {
            onFailure?("No active window was available to show the file picker. Close any open menu or sheet and try again.")
            return
        }

        // A sheet that is still animating away cannot be presented over. Wait
        // for it to finish instead of letting UIKit drop the presentation.
        if let presented = presenter.presentedViewController,
           presented.isBeingDismissed,
           retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.present(
                    contentTypes: contentTypes,
                    allowsMultipleSelection: allowsMultipleSelection,
                    onPicked: onPicked,
                    onFailure: onFailure,
                    retries: retries - 1
                )
            }
            return
        }

        completion = onPicked

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .formSheet
        picker.preferredContentSize = CGSize(width: 580, height: 600)
        if let popover = picker.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        picker.modalTransitionStyle = .coverVertical

        activePicker = picker
        presenter.present(picker, animated: true, completion: nil)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        deliver(urls: urls, dismissing: controller)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliver(urls: [], dismissing: controller)
    }

    private func deliver(urls: [URL], dismissing controller: UIViewController) {
        let callback = completion
        completion = nil
        activePicker = nil

        // The picker must be gone before the library enqueues work, otherwise
        // the banner and alert can be covered by a half-dismissed sheet.
        let finish = {
            guard !urls.isEmpty else {
                callback?([])
                return
            }

            // Building a `PickedDocument` claims the security scope and tests
            // readability. Keep that off the main thread: the coordinated copy
            // fallback can touch a multi-gigabyte file.
            DispatchQueue.global(qos: .userInitiated).async {
                let documents = urls.map(PickedDocument.init(url:))
                DispatchQueue.main.async {
                    callback?(documents)
                }
            }
        }

        if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: finish)
        } else {
            finish()
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
        let keyWindow = windows.first(where: { $0.isKeyWindow && !$0.isHidden })
            ?? windows.first(where: { !$0.isHidden })
            ?? windows.first
        return topmost(from: keyWindow?.rootViewController)
    }

    private static func topmost(from controller: UIViewController?, depth: Int = 0) -> UIViewController? {
        guard let controller = controller else { return nil }
        guard depth < 12 else { return controller }

        // A controller that is mid-dismissal cannot present. Present from the
        // controller that is about to become visible again, which is what fixes
        // the menu/sheet-close race on iPadOS 15.
        if controller.isBeingDismissed {
            guard let presenter = controller.presentingViewController else { return nil }
            return topmost(from: presenter, depth: depth + 1)
        }

        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return topmost(from: presented, depth: depth + 1)
        }
        if let navigation = controller as? UINavigationController {
            return topmost(from: navigation.visibleViewController ?? navigation, depth: depth + 1)
        }
        if let tab = controller as? UITabBarController {
            return topmost(from: tab.selectedViewController ?? tab, depth: depth + 1)
        }
        return controller
    }
}

enum DocumentPickerTypes {

    /// Every archive kind. Explicit types keep `.apk`, `.zip`, `.7z` and `.rar`
    /// enabled in Files.app; `.item` remains as the catch-all for folders.
    static var archives: [UTType] {
        var types: [UTType] = [.item, .data]
        for fileExtension in ["zip", "apk", "7z", "rar", "cbz", "cb7", "cbr", "ipa"] {
            guard let type = UTType(filenameExtension: fileExtension) else { continue }
            if !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    static var images: [UTType] { [.image] }
}
