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

            let navController = self.makeContactNavigationController(for: contact, contactStore: contactStore)
            self.presentedNavController = navController
            await self.present(navController)
        }
    }

    func addEmailToContact(existingContact: CNContact, emailToAdd: String) {
        emailToInvalidate = emailToAdd

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let contactName = CNContactFormatter.string(from: existingContact, style: .fullName) ?? "this contact"

            // Show confirmation alert before saving
            let confirmAlert = UIAlertController(
                title: "Add Email",
                message: "Add \(emailToAdd) to \(contactName)?",
                preferredStyle: .alert
            )

            confirmAlert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
                guard let self else { return }
                self.performAddEmail(
                    toContactIdentifier: existingContact.identifier,
                    emailToAdd: emailToAdd,
                    preferredPresenter: confirmAlert.presentingViewController
                )
            })

            confirmAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            await self.present(confirmAlert)
        }
    }

    private func performAddEmail(
        toContactIdentifier contactIdentifier: String,
        emailToAdd: String,
        preferredPresenter: UIViewController?
    ) {
        let normalizedEmailToAdd = emailToAdd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Ensure we have enough data to update + re-display.
        let keysToFetch: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let updateResult: Result<CNContact, Error> = await Task.detached(priority: .userInitiated) {
                let contactStore = CNContactStore()
                do {
                    let contact = try contactStore.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keysToFetch)
                    guard let mutableContact = contact.mutableCopy() as? CNMutableContact else {
                        return .failure(NSError(domain: "esc-chatmail", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Failed to create editable contact copy."
                        ]))
                    }

                    let hasEmailAlready = contact.emailAddresses.contains { labeledValue in
                        let existing = (labeledValue.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return existing == normalizedEmailToAdd
                    }

                    if !hasEmailAlready {
                        mutableContact.emailAddresses.append(
                            CNLabeledValue(label: CNLabelOther, value: emailToAdd as NSString)
                        )

                        let saveRequest = CNSaveRequest()
                        saveRequest.update(mutableContact)
                        try contactStore.execute(saveRequest)
                    }

                    let updated = try contactStore.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keysToFetch)
                    return .success(updated)
                } catch {
                    return .failure(error)
                }
            }.value

            switch updateResult {
            case .success:
                Task {
                    await ContactsResolver.shared.invalidateCache(for: emailToAdd)
                    await PersonCache.shared.invalidateEntry(for: emailToAdd)
                }

            case .failure(let error):
                Log.error("Failed to add email to contact", category: .ui, error: error)

                let status = CNContactStore.authorizationStatus(for: .contacts)
                var message = error.localizedDescription
                var showSettingsButton = false

                switch status {
                case .denied:
                    message = "MushMail doesn’t have permission to edit contacts. Allow Contacts access in Settings, then try again."
                    showSettingsButton = true
                case .restricted:
                    message = "Contacts access is restricted on this device."
                case .notDetermined:
                    message = "Contacts access hasn’t been granted yet. Allow access in Settings, then try again."
                    showSettingsButton = true
                default:
                    if #available(iOS 18.0, *), status == .limited {
                        message = "MushMail has limited Contacts access and can only edit contacts you’ve shared with it. Allow access to this contact (or full access) in Settings, then try again."
                        showSettingsButton = true
                    }
                }

                let alert = UIAlertController(
                    title: "Couldn’t Save Contact",
                    message: message,
                    preferredStyle: .alert
                )

                if showSettingsButton, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                        UIApplication.shared.open(settingsURL)
                    })
                }

                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                await self.present(alert, preferredPresenter: preferredPresenter)
            }
        }
    }

    @MainActor
    private func present(_ viewController: UIViewController, preferredPresenter: UIViewController? = nil) async {
        guard await TopPresentableViewController.present(viewController, preferredPresenter: preferredPresenter) else {
            Log.error("Failed to find active presenter for contact UI", category: .ui)
            return
        }
    }

    private func makeContactNavigationController(
        for contact: CNContact,
        contactStore: CNContactStore
    ) -> UINavigationController {
        let contactViewController = CNContactViewController(for: contact)
        contactViewController.contactStore = contactStore
        contactViewController.delegate = self
        contactViewController.allowsEditing = true
        contactViewController.navigationItem.rightBarButtonItem = contactViewController.editButtonItem
        contactViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(self.dismissTapped)
        )

        let navigationController = UINavigationController(rootViewController: contactViewController)
        navigationController.modalPresentationStyle = .pageSheet
        return navigationController
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
