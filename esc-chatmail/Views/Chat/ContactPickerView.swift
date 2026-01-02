import SwiftUI
import Contacts
import ContactsUI

struct ContactPickerView: UIViewControllerRepresentable {
    let onContactSelected: (CNContact) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onContactSelected: onContactSelected,
            onCancel: onCancel,
            dismiss: dismiss
        )
    }

    class Coordinator: NSObject, CNContactPickerDelegate {
        let onContactSelected: (CNContact) -> Void
        let onCancel: () -> Void
        let dismiss: DismissAction

        init(
            onContactSelected: @escaping (CNContact) -> Void,
            onCancel: @escaping () -> Void,
            dismiss: DismissAction
        ) {
            self.onContactSelected = onContactSelected
            self.onCancel = onCancel
            self.dismiss = dismiss
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onContactSelected(contact)
            dismiss()
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
            dismiss()
        }
    }
}
