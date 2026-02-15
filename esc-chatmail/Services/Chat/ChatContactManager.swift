import Foundation
import Contacts
import ContactsUI

/// Manages contact-related operations for ChatView
@MainActor
final class ChatContactManager: ObservableObject {
    // MARK: - Alerts

    struct ContactActionAlert: Identifiable {
        enum Kind {
            case contactsDenied
            case contactsRestricted
            case limitedAccessNeedsPermission(contactName: String)
            case error(message: String)
        }

        let id = UUID()
        let kind: Kind
    }

    // MARK: - Published State

    @Published var contactToAdd: ContactWrapper?
    @Published var showingParticipantsList = false

    // Add to existing contact flow state
    @Published var showingContactPicker = false
    @Published var showingContactAccessPicker = false
    @Published var contactActionAlert: ContactActionAlert?

    // MARK: - Contact Actions

    private var pendingEmailToAddToExistingContact: String?
    private var pendingSelectedContactIdentifierRequiringPermission: String?
    private var pendingSelectedContactNameRequiringPermission: String?

    func prepareContactToAdd(for person: Person) {
        let contact = CNMutableContact()

        if let displayName = person.displayName, !displayName.isEmpty {
            let components = displayName.components(separatedBy: " ")
            if components.count >= 2 {
                contact.givenName = components[0]
                contact.familyName = components.dropFirst().joined(separator: " ")
            } else {
                contact.givenName = displayName
            }
        }

        let email = person.email
        contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]

        showingParticipantsList = false
        contactToAdd = ContactWrapper(contact: contact)
    }

    /// Called when user selects "Create New Contact"
    func createNewContact(for person: Person) {
        prepareContactToAdd(for: person)
    }

    /// Called when user selects "Add to Existing Contact"
    func addToExistingContact(for person: Person) {
        showingParticipantsList = false
        pendingEmailToAddToExistingContact = person.email

        Task { [weak self] in
            guard let self else { return }

            let status = await requestContactsAccessIfNeeded()
            if #available(iOS 18.0, *), status == .limited {
                // Limited access can still edit permitted contacts; we may need the access picker later.
                showingContactPicker = true
                return
            }

            if status == .authorized {
                showingContactPicker = true
                return
            }

            if status == .notDetermined || status == .denied {
                pendingEmailToAddToExistingContact = nil
                contactActionAlert = ContactActionAlert(kind: .contactsDenied)
                return
            }

            if status == .restricted {
                pendingEmailToAddToExistingContact = nil
                contactActionAlert = ContactActionAlert(kind: .contactsRestricted)
                return
            }

            pendingEmailToAddToExistingContact = nil
            contactActionAlert = ContactActionAlert(kind: .error(message: "Contacts access is unavailable."))
        }
    }

    /// Called when user picks a contact from the picker
    func handleContactSelected(_ contact: CNContact) {
        let contactIdentifier = contact.identifier
        guard let emailToAdd = pendingEmailToAddToExistingContact else { return }

        // Clear state immediately for responsive UI
        showingContactPicker = false

        let selectedContactName = Self.displayName(for: contact)

        Task { [weak self] in
            guard let self else { return }
            let keysToFetch: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]

            do {
                let fullContact = try await Task.detached(priority: .userInitiated) {
                    try CNContactStore().unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keysToFetch)
                }.value

                ContactPresenter.shared.addEmailToContact(existingContact: fullContact, emailToAdd: emailToAdd)
                pendingEmailToAddToExistingContact = nil
                pendingSelectedContactIdentifierRequiringPermission = nil
                pendingSelectedContactNameRequiringPermission = nil
            } catch {
                Log.error("Failed to fetch contact for editing", category: .ui, error: error)

                let status = CNContactStore.authorizationStatus(for: .contacts)
                if status == .denied {
                    pendingEmailToAddToExistingContact = nil
                    pendingSelectedContactIdentifierRequiringPermission = nil
                    pendingSelectedContactNameRequiringPermission = nil
                    contactActionAlert = ContactActionAlert(kind: .contactsDenied)
                    return
                }

                if status == .restricted {
                    pendingEmailToAddToExistingContact = nil
                    pendingSelectedContactIdentifierRequiringPermission = nil
                    pendingSelectedContactNameRequiringPermission = nil
                    contactActionAlert = ContactActionAlert(kind: .contactsRestricted)
                    return
                }

                if #available(iOS 18.0, *), status == .limited {
                    // Under limited access, the system contact picker always shows all contacts but does not
                    // automatically grant access to the selected contact for CNContactStore operations.
                    pendingSelectedContactIdentifierRequiringPermission = contactIdentifier
                    pendingSelectedContactNameRequiringPermission = selectedContactName
                    contactActionAlert = ContactActionAlert(
                        kind: .limitedAccessNeedsPermission(contactName: selectedContactName)
                    )
                    return
                }

                pendingEmailToAddToExistingContact = nil
                pendingSelectedContactIdentifierRequiringPermission = nil
                pendingSelectedContactNameRequiringPermission = nil
                contactActionAlert = ContactActionAlert(kind: .error(message: error.localizedDescription))
            }
        }
    }

    /// Called when user cancels the contact picker
    func handleContactPickerCancelled() {
        showingContactPicker = false
        pendingEmailToAddToExistingContact = nil
        pendingSelectedContactIdentifierRequiringPermission = nil
        pendingSelectedContactNameRequiringPermission = nil
    }

    /// Called when tapping on an existing contact (green checkmark)
    func editExistingContact(identifier: String) {
        // Don't dismiss participants list - it causes a race condition with contact presentation
        // The contact card presents on top, and user can dismiss participants list after
        ContactPresenter.shared.presentContact(identifier: identifier)
    }

    // MARK: - Limited Access (iOS 18+)

    func presentContactAccessPickerForSelectedContact() {
        guard #available(iOS 18.0, *) else { return }
        showingContactAccessPicker = true
    }

    func handleContactAccessPickerCompletion(_ identifiers: [String]) {
        guard #available(iOS 18.0, *) else { return }
        showingContactAccessPicker = false

        // Treat an empty selection as cancel.
        guard !identifiers.isEmpty else {
            pendingSelectedContactIdentifierRequiringPermission = nil
            pendingSelectedContactNameRequiringPermission = nil
            pendingEmailToAddToExistingContact = nil
            return
        }

        guard let pendingContactIdentifier = pendingSelectedContactIdentifierRequiringPermission,
              let emailToAdd = pendingEmailToAddToExistingContact else {
            pendingSelectedContactIdentifierRequiringPermission = nil
            pendingSelectedContactNameRequiringPermission = nil
            pendingEmailToAddToExistingContact = nil
            return
        }

        guard identifiers.contains(pendingContactIdentifier) else {
            let contactName = pendingSelectedContactNameRequiringPermission ?? "the selected contact"
            pendingSelectedContactIdentifierRequiringPermission = nil
            pendingSelectedContactNameRequiringPermission = nil
            pendingEmailToAddToExistingContact = nil
            contactActionAlert = ContactActionAlert(
                kind: .error(message: "To edit \(contactName), select it in the access picker and try again.")
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let keysToFetch: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]
            do {
                let fullContact = try await Task.detached(priority: .userInitiated) {
                    try CNContactStore().unifiedContact(withIdentifier: pendingContactIdentifier, keysToFetch: keysToFetch)
                }.value

                ContactPresenter.shared.addEmailToContact(existingContact: fullContact, emailToAdd: emailToAdd)
            } catch {
                Log.error("Failed to fetch contact after granting permission", category: .ui, error: error)
                contactActionAlert = ContactActionAlert(kind: .error(message: error.localizedDescription))
            }

            pendingSelectedContactIdentifierRequiringPermission = nil
            pendingSelectedContactNameRequiringPermission = nil
            pendingEmailToAddToExistingContact = nil
        }
    }

    // MARK: - Helpers

    private func requestContactsAccessIfNeeded() async -> CNAuthorizationStatus {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        guard current == .notDetermined else { return current }

        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            Log.error("Failed to request contacts access", category: .ui, error: error)
        }

        return CNContactStore.authorizationStatus(for: .contacts)
    }

    private static func displayName(for contact: CNContact) -> String {
        let givenName: String
        if contact.isKeyAvailable(CNContactGivenNameKey) {
            givenName = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            givenName = ""
        }

        let familyName: String
        if contact.isKeyAvailable(CNContactFamilyNameKey) {
            familyName = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            familyName = ""
        }

        let joined = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? "the selected contact" : joined
    }
}

// MARK: - Contact Wrapper for Identifiable
struct ContactWrapper: Identifiable {
    let id = UUID()
    let contact: CNMutableContact
}
