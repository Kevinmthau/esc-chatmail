import UIKit
import Contacts
import ContactsUI

class ContactPresenter: NSObject, CNContactViewControllerDelegate {
    static let shared = ContactPresenter()

    private weak var presentedNavController: UINavigationController?
    private var emailToInvalidate: String?
    private var isObservingContactStoreDidChange = false

    func presentContact(identifier: String) {
        emailToInvalidate = nil
        removeContactStoreDidChangeObserver()

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
            // Ensure the Edit/Done control exists even when presented modally.
            contactVC.navigationItem.rightBarButtonItem = contactVC.editButtonItem
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
        removeContactStoreDidChangeObserver()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Delay to allow any dismissing sheets to complete
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let topVC = self.getTopViewController() else { return }

            let contactName = CNContactFormatter.string(from: existingContact, style: .fullName) ?? "this contact"

            // Show confirmation alert before saving
            let confirmAlert = UIAlertController(
                title: "Add Email",
                message: "Add \(emailToAdd) to \(contactName)?",
                preferredStyle: .alert
            )

            confirmAlert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
                guard let self else { return }
                self.performAddEmail(toContactIdentifier: existingContact.identifier, emailToAdd: emailToAdd, from: topVC)
            })

            confirmAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            topVC.present(confirmAlert, animated: true)
        }
    }

    private func performAddEmail(toContactIdentifier contactIdentifier: String, emailToAdd: String, from topVC: UIViewController) {
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
            case .success(let updatedContact):
                Task {
                    await ContactsResolver.shared.invalidateCache(for: emailToAdd)
                    await PersonCache.shared.invalidateEntry(for: emailToAdd)
                }

                let alert = UIAlertController(
                    title: "Saved",
                    message: "Added \(emailToAdd) to this contact.",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "View Contact", style: .default) { [weak self] _ in
                    guard let self else { return }

                    let contactVC = CNContactViewController(for: updatedContact)
                    contactVC.contactStore = CNContactStore()
                    contactVC.delegate = self
                    contactVC.allowsEditing = true
                    contactVC.navigationItem.rightBarButtonItem = contactVC.editButtonItem
                    contactVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
                        barButtonSystemItem: .close,
                        target: self,
                        action: #selector(self.dismissTapped)
                    )

                    let navController = UINavigationController(rootViewController: contactVC)
                    navController.modalPresentationStyle = .pageSheet
                    self.presentedNavController = navController
                    topVC.present(navController, animated: true)
                })

                alert.addAction(UIAlertAction(title: "Done", style: .cancel))
                topVC.present(alert, animated: true)

            case .failure(let error):
                Log.error("Failed to add email to contact", category: .ui, error: error)

                let status = CNContactStore.authorizationStatus(for: .contacts)
                var message = error.localizedDescription
                var showSettingsButton = false

                switch status {
                case .denied:
                    message = "ESC Chatmail doesn’t have permission to edit contacts. Allow Contacts access in Settings, then try again."
                    showSettingsButton = true
                case .restricted:
                    message = "Contacts access is restricted on this device."
                case .notDetermined:
                    message = "Contacts access hasn’t been granted yet. Allow access in Settings, then try again."
                    showSettingsButton = true
                default:
                    if #available(iOS 18.0, *), status == .limited {
                        message = "ESC Chatmail has limited Contacts access and can only edit contacts you’ve shared with it. Allow access to this contact (or full access) in Settings, then try again."
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
                topVC.present(alert, animated: true)
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
        removeContactStoreDidChangeObserver()
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
        removeContactStoreDidChangeObserver()
        presentedNavController?.dismiss(animated: true)
    }

    @objc private func contactStoreDidChange(_ notification: Notification) {
        guard let email = emailToInvalidate else { return }
        removeContactStoreDidChangeObserver()
        Task {
            await ContactsResolver.shared.invalidateCache(for: email)
            await PersonCache.shared.invalidateEntry(for: email)
        }
    }

    private func startObservingContactStoreDidChange() {
        guard !isObservingContactStoreDidChange else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contactStoreDidChange(_:)),
            name: .CNContactStoreDidChange,
            object: nil
        )
        isObservingContactStoreDidChange = true
    }

    private func removeContactStoreDidChangeObserver() {
        guard isObservingContactStoreDidChange else { return }
        NotificationCenter.default.removeObserver(self, name: .CNContactStoreDidChange, object: nil)
        isObservingContactStoreDidChange = false
    }
}
