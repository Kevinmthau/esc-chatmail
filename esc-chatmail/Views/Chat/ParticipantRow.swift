import SwiftUI

struct ParticipantRow: View {
    let person: Person
    let onCreateNewContact: () -> Void
    let onAddToExistingContact: () -> Void
    let onEditContact: (String) -> Void

    @State private var isExistingContact = false
    @State private var contactIdentifier: String?
    private let contactsResolver = ContactsResolver.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                let trimmedDisplayName = person.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = (trimmedDisplayName?.isEmpty == false) ? trimmedDisplayName : nil
                let trimmedEmail = person.email.trimmingCharacters(in: .whitespacesAndNewlines)

                Text(displayName ?? trimmedEmail)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let displayName,
                   !displayName.localizedCaseInsensitiveContains(trimmedEmail) {
                    Text(trimmedEmail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isExistingContact {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Menu {
                    Button("Create New Contact") {
                        onCreateNewContact()
                    }
                    Button("Add to Existing Contact") {
                        onAddToExistingContact()
                    }
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isExistingContact, let identifier = contactIdentifier {
                onEditContact(identifier)
            }
        }
        .task {
            if let match = await contactsResolver.lookup(email: person.email) {
                isExistingContact = match.contactIdentifier != nil
                contactIdentifier = match.contactIdentifier
            }
        }
    }
}
