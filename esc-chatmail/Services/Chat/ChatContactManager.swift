import Foundation
import Contacts
import ContactsUI

/// Manages contact-related operations for ChatView
@MainActor
final class ChatContactManager: ObservableObject {
    // MARK: - Published State

    @Published var contactToAdd: ContactWrapper?
    @Published var showingParticipantsList = false

    // Contact action sheet state
    @Published var showingContactActionSheet = false
    @Published var personForContactAction: Person?

    // Add to existing contact flow state
    @Published var showingContactPicker = false
    @Published var personForExistingContact: Person?

    // MARK: - Contact Actions

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

    /// Called when tapping the add contact button - shows action sheet
    func showContactActionSheet(for person: Person) {
        personForContactAction = person
        showingParticipantsList = false
        showingContactActionSheet = true
    }

    /// Called when user selects "Create New Contact"
    func createNewContact() {
        guard let person = personForContactAction else { return }
        prepareContactToAdd(for: person)
        personForContactAction = nil
        showingContactActionSheet = false
    }

    /// Called when user selects "Add to Existing Contact"
    func addToExistingContact() {
        guard let person = personForContactAction else { return }
        personForExistingContact = person
        showingContactActionSheet = false
        showingContactPicker = true
    }

    /// Called when user picks a contact from the picker
    func handleContactSelected(_ contact: CNContact) {
        guard let person = personForExistingContact else { return }

        let contactIdentifier = contact.identifier
        let emailToAdd = person.email

        // Clear state immediately for responsive UI
        personForExistingContact = nil
        showingContactPicker = false

        Task {
            let contactStore = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()]

            // Background thread for CNContactStore
            let fullContact: CNContact? = await Task.detached(priority: .userInitiated) {
                try? contactStore.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keysToFetch)
            }.value

            guard let contact = fullContact else {
                Log.error("Failed to fetch contact for editing", category: .ui)
                return
            }

            ContactPresenter.shared.addEmailToContact(existingContact: contact, emailToAdd: emailToAdd)
        }
    }

    /// Called when user cancels the contact picker
    func handleContactPickerCancelled() {
        personForExistingContact = nil
        showingContactPicker = false
    }

    /// Called when tapping on an existing contact (green checkmark)
    func editExistingContact(identifier: String) {
        // Don't dismiss participants list - it causes a race condition with contact presentation
        // The contact card presents on top, and user can dismiss participants list after
        ContactPresenter.shared.presentContact(identifier: identifier)
    }
}

// MARK: - Contact Wrapper for Identifiable
struct ContactWrapper: Identifiable {
    let id = UUID()
    let contact: CNMutableContact
}
