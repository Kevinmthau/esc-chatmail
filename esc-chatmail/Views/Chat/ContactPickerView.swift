import SwiftUI
import Contacts
import ContactsUI

struct ContactPickerView: UIViewControllerRepresentable {
    let onContactSelected: (CNContact) -> Void
    let onCancel: () -> Void
    /// Controls which contact properties (if any) are shown as subtitle text in the picker list.
    /// Use an empty array (`[]`) to show name only.
    let displayedPropertyKeys: [String]?
    @Environment(\.dismiss) private var dismiss

    init(
        onContactSelected: @escaping (CNContact) -> Void,
        onCancel: @escaping () -> Void,
        displayedPropertyKeys: [String]? = nil
    ) {
        self.onContactSelected = onContactSelected
        self.onCancel = onCancel
        self.displayedPropertyKeys = displayedPropertyKeys
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = displayedPropertyKeys
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
