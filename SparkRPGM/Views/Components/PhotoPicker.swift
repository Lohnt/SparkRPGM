import SwiftUI
import PhotosUI
import UIKit

/// iOS 15 safe Photos picker (PHPickerViewController).
///
/// Using PHPicker means no `NSPhotoLibraryUsageDescription` permission prompt
/// and no access to the user's whole library.
struct PhotoPicker: UIViewControllerRepresentable {

    @Binding var isPresented: Bool
    let onPicked: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true) {
                DispatchQueue.main.async {
                    self.parent.isPresented = false
                }
            }

            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }

            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error = error {
                    Log.error("Photo picker load failed", error: error)
                    return
                }
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async {
                    self.parent.onPicked(image)
                }
            }
        }
    }
}
