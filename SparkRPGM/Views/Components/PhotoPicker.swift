import UIKit
import PhotosUI

/// Direct UIKit wrapper around `PHPickerViewController`.
///
/// Like `DocumentPickerPresenter`, this presents from the key window instead of
/// a nested SwiftUI sheet. On iPadOS 15 a second `.sheet` inside the
/// customization sheet could dismiss without ever invoking its callback, which
/// made picking a wallpaper silently do nothing.
///
/// `PHPicker` needs no photo-library permission and only ever sees the image the
/// player explicitly selects.
final class PhotoPickerPresenter: NSObject, PHPickerViewControllerDelegate {

    static let shared = PhotoPickerPresenter()

    private var completion: ((UIImage?) -> Void)?

    private override init() {
        super.init()
    }

    func present(onPicked: @escaping (UIImage?) -> Void) {
        guard let presenter = ViewPresenter.topViewController() else { return }

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        completion = onPicked

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        presenter.present(picker, animated: true, completion: nil)
    }

    // MARK: - PHPickerViewControllerDelegate

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let callback = completion
        completion = nil

        picker.dismiss(animated: true) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                DispatchQueue.main.async { callback?(nil) }
                return
            }

            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error = error {
                    Log.error("Photo picker load failed", error: error)
                }
                let image = object as? UIImage
                DispatchQueue.main.async {
                    callback?(image)
                }
            }
        }
    }
}
