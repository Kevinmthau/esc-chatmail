import UIKit
import Contacts
import ContactsUI

class ContactPresenter: NSObject, CNContactViewControllerDelegate {
    static let shared = ContactPresenter()

    private weak var presentedNavController: UINavigationController?
    private var emailToInvalidate: String?

    func presentContact(identifier: String) {
        emailToInvalidate = nil

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Delay to allow any dismissing sheets to complete
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let topVC = self.getTopViewController() else { return }

            let keysToFetch: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]
            let contactStore = CNContactStore()

            // Background thread for CNContactStore
            let contact: CNContact? = await Task.detached(priority: .userInitiated) {
                try? contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
            }.value

            guard let contact = contact else {
                Log.error("Failed to fetch contact", category: .ui)
                return
            }

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
        }
    }

    func addEmailToContact(existingContact: CNContact, emailToAdd: String) {
        emailToInvalidate = emailToAdd

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Delay to allow any dismissing sheets to complete
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let topVC = self.getTopViewController() else { return }

            guard let mutableContact = existingContact.mutableCopy() as? CNMutableContact else {
                Log.error("Failed to create mutable copy of contact", category: .ui)
                return
            }
            mutableContact.emailAddresses.append(
                CNLabeledValue(label: CNLabelOther, value: emailToAdd as NSString)
            )

            let saveRequest = CNSaveRequest()
            saveRequest.update(mutableContact)
            let contactStore = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]
            let contactIdentifier = existingContact.identifier

            // Background thread for CNContactStore save + fetch
            let updatedContact: CNContact? = await Task.detached(priority: .userInitiated) {
                do {
                    try contactStore.execute(saveRequest)
                    return try contactStore.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keysToFetch)
                } catch {
                    Log.error("Failed to save email to contact", category: .ui, error: error)
                    return nil
                }
            }.value

            guard let contact = updatedContact else { return }

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

            Task {
                await ContactsResolver.shared.invalidateCache(for: emailToAdd)
                await PersonCache.shared.invalidateEntry(for: emailToAdd)
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
                await PersonCache.shared.invalidateEntry(for: email)
            }
        }
        presentedNavController?.dismiss(animated: true)
    }

    func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        if let contact = contact {
            Task {
                for email in contact.emailAddresses {
                    let emailString = email.value as String
                    await ContactsResolver.shared.invalidateCache(for: emailString)
                    await PersonCache.shared.invalidateEntry(for: emailString)
                }
            }
        }
        if let email = emailToInvalidate {
            Task {
                await ContactsResolver.shared.invalidateCache(for: email)
                await PersonCache.shared.invalidateEntry(for: email)
            }
        }
        presentedNavController?.dismiss(animated: true)
    }
}
