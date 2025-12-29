import SwiftUI
import Contacts
import ContactsUI

struct AddContactView: UIViewControllerRepresentable {
    let contact: CNMutableContact
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let contactVC = CNContactViewController(forNewContact: contact)
        contactVC.contactStore = CNContactStore()
        contactVC.delegate = context.coordinator

        let navController = UINavigationController(rootViewController: contactVC)
        navController.modalPresentationStyle = .formSheet
        return navController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject, CNContactViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}
