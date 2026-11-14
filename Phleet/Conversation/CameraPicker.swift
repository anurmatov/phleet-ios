import SwiftUI
import UIKit

/// The system's camera, for one photo to send.
///
/// The system's own screen, presented and dismissed by the system: this app draws none of it and
/// keeps nothing but the photo that was taken. The photo goes through the same preparation as one
/// picked from the library, so what is sent is a JPEG of a sensible size whatever the camera wrote.
struct CameraPicker: UIViewControllerRepresentable {

    /// Whether this device has a camera to offer. A simulator and some iPads in a stage do not,
    /// and the choice is then left out rather than offered and refused.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Given the photo's bytes, or `nil` when the camera was dismissed without one.
    let onFinish: (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

        private let onFinish: (Data?) -> Void

        init(onFinish: @escaping (Data?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // Handed on as JPEG bytes: the same thing the library picker hands over, so one
            // preparation path serves both.
            let photo = info[.originalImage] as? UIImage
            onFinish(photo?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
