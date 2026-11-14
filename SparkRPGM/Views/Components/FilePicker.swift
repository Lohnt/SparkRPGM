import SwiftUI
import UniformTypeIdentifiers

/// UIDocumentPickerViewController wrapper used for archives and images.
///
/// `asCopy: false` hands us a security-scoped URL, which lets SparkRPGM read a
/// 15 GB archive in place instead of duplicating it before extraction.
struct FilePicker: UIViewControllerRepresentable {

    @Binding var isPresented: Bool
    let contentTypes: [UTType]
    var allowsMultipleSelection: Bool = false
    let onPicked: ([URL]) -> Void
    var onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        private let parent: FilePicker

        init(_ parent: FilePicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let picked = urls
            controller.dismiss(animated: true) {
                DispatchQueue.main.async {
                    self.parent.isPresented = false
                    self.parent.onPicked(picked)
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: true) {
                DispatchQueue.main.async {
                    self.parent.isPresented = false
                    self.parent.onCancel?()
                }
            }
        }
    }
}

enum FilePickerTypes {

    /// "Open in SparkRPGM" style import: any archive, APK or folder.
    static var archives: [UTType] {
        var types: [UTType] = [.item, .data]
        for identifier in [
            "com.pkware.zip-archive",
            "org.7-zip.7-zip-archive",
            "com.rarlab.rar-archive",
            "com.android.package-archive",
        ] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        return types
    }

    static var images: [UTType] {
        [.image]
    }
}
