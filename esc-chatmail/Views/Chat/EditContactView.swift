import UIKit
import Contacts
import ContactsUI

class ContactPresenter: NSObject, CNContactViewControllerDelegate {
    static let shared = ContactPresenter()

    private weak var presentedNavController: UINavigationController?
    private var emailToInvalidate: String?

    func presentContact(identifier: String) {
        emailToInvalidate = nil

        // Delay to allow any dismissing sheets to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard let topVC = self.getTopViewController() else { return }

            let contactStore = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactViewController.descriptorForRequiredKeys()
            ]

            do {
                let contact = try contactStore.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: keysToFetch
                )

                let contactVC = CNContactViewController(for: contact)
                contactVC.contactStore = contactStore
                contactVC.delegate = self
                contactVC.allowsEditing = true
                contactVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .close,
                    target: self,
                    action: #selector(self.dismissTapped)
                )

                let navController = UINavigationController(rootViewController: contactVC)
                navController.modalPresentationStyle = .pageSheet
                self.presentedNavController = navController
                topVC.present(navController, animated: true)
            } catch {
                Log.error("Failed to fetch contact", category: .ui, error: error)
            }
        }
    }

    func addEmailToContact(existingContact: CNContact, emailToAdd: String) {
        emailToInvalidate = emailToAdd

        // Delay to allow any dismissing sheets to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard let topVC = self.getTopViewController() else { return }

            let contactStore = CNContactStore()

            // Create mutable copy and add the email
            let mutableContact = existingContact.mutableCopy() as! CNMutableContact
            let newEmail = CNLabeledValue(label: CNLabelOther, value: emailToAdd as NSString)
            mutableContact.emailAddresses.append(newEmail)

            // Save the updated contact
            let saveRequest = CNSaveRequest()
            saveRequest.update(mutableContact)

            do {
                try contactStore.execute(saveRequest)

                // Fetch the updated contact to display
                let keysToFetch: [CNKeyDescriptor] = [
                    CNContactViewController.descriptorForRequiredKeys()
                ]
                let updatedContact = try contactStore.unifiedContact(
                    withIdentifier: existingContact.identifier,
                    keysToFetch: keysToFetch
                )

                let contactVC = CNContactViewController(for: updatedContact)
                contactVC.contactStore = contactStore
                contactVC.delegate = self
                contactVC.allowsEditing = true
                contactVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .close,
                    target: self,
                    action: #selector(self.dismissTapped)
                )

                let navController = UINavigationController(rootViewController: contactVC)
                navController.modalPresentationStyle = .pageSheet
                self.presentedNavController = navController
                topVC.present(navController, animated: true)

                // Invalidate cache for the email we added
                Task {
                    await ContactsResolver.shared.invalidateCache(for: emailToAdd)
                }
            } catch {
                Log.error("Failed to save email to contact", category: .ui, error: error)
            }
        }
    }

    private func getTopViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return nil }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }

    @objc private func dismissTapped() {
        if let email = emailToInvalidate {
            Task {
                await ContactsResolver.shared.invalidateCache(for: email)
            }
        }
        presentedNavController?.dismiss(animated: true)
    }

    func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        if let contact = contact {
            Task {
                for email in contact.emailAddresses {
                    await ContactsResolver.shared.invalidateCache(for: email.value as String)
                }
            }
        }
        if let email = emailToInvalidate {
            Task {
                await ContactsResolver.shared.invalidateCache(for: email)
            }
        }
        presentedNavController?.dismiss(animated: true)
    }
}
