import Foundation
import UIKit

/// PLAN.md 3.48.4 「通过中转发送图片」: its own picker, deliberately not the chat's ordinary attachment sheet —
/// touching that pipeline is exactly what PLAN.md 3.48.0 forbids (the existing media-sending pipeline must not
/// change). A plain `UIImagePickerController` is enough: this never becomes a normal attachment, it becomes the
/// bytes this component uploads itself.
final class SecutgRelayImagePicker: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onPicked: (Data, String) -> Void
    /// Keeps itself alive for the lifetime of the picker — nothing else holds a strong reference to a delegate
    /// object created ad hoc like this one.
    private static var retained: [SecutgRelayImagePicker] = []

    init(onPicked: @escaping (Data, String) -> Void) {
        self.onPicked = onPicked
    }

    func makePickerController() -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        SecutgRelayImagePicker.retained.append(self)
        return picker
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        defer { release(picker) }
        guard let image = (info[.originalImage] as? UIImage), let data = image.jpegData(compressionQuality: 0.95) else { return }
        onPicked(data, "image/jpeg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        release(picker)
    }

    private func release(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        SecutgRelayImagePicker.retained.removeAll(where: { $0 === self })
    }
}
