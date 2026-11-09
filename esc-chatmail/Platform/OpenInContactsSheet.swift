#if os(macOS)
import SwiftUI
import Contacts

/// The Mac's Contacts sheet (`ContactsSheet`): ContactsUI's new-contact and picker controllers
/// are iOS-only, so it offers to open the Contacts app instead.
///
/// For a new contact it shows who would be added and hands the prefilled card to Contacts,
/// whose own import confirmation adds it (`ContactsAppLink.openNewContact`). Choosing an
/// existing contact is not offered on the Mac (`ContactsSheet.supportsContactPicker`); if a
/// picker is ever requested anyway, it opens the Contacts app and reports a cancel.
struct OpenInContactsSheet: View {
    private enum Mode {
        case newContact(CNMutableContact)
        case contactPicker(onCancel: () -> Void)
    }

    private let mode: Mode
    @Environment(\.dismiss) private var dismiss

    init(newContact contact: CNMutableContact) {
        mode = .newContact(contact)
    }

    init(onCancel: @escaping () -> Void) {
        mode = .contactPicker(onCancel: onCancel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            if let name = contactName {
                Text(name)
            }
            ForEach(emailAddresses, id: \.self) { email in
                Text(email)
                    .foregroundColor(.secondary)
            }
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open in Contacts") {
                    openInContacts()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private var title: String {
        switch mode {
        case .newContact: return "New Contact"
        case .contactPicker: return "Contacts"
        }
    }

    private var message: String {
        switch mode {
        case .newContact:
            return "Contacts opens with this card so you can review it and add it."
        case .contactPicker:
            return "Choose and edit contacts in the Contacts app."
        }
    }

    private var contactName: String? {
        guard case .newContact(let contact) = mode else { return nil }
        let name = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private var emailAddresses: [String] {
        guard case .newContact(let contact) = mode else { return [] }
        return contact.emailAddresses.map { String($0.value) }
    }

    private func cancel() {
        if case .contactPicker(let onCancel) = mode {
            onCancel()
        }
        dismiss()
    }

    private func openInContacts() {
        switch mode {
        case .newContact(let contact):
            ContactsAppLink.openNewContact(contact)
        case .contactPicker(let onCancel):
            ContactsAppLink.openContactsApp()
            onCancel()
        }
        dismiss()
    }
}
#endif
