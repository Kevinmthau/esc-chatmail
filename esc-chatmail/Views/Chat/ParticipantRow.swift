import SwiftUI

struct ParticipantRow: View {
    let displayName: String
    let email: String
    let isExistingContact: Bool
    let contactIdentifier: String?
    let onCreateNewContact: () -> Void
    let onAddToExistingContact: () -> Void
    let onEditContact: (String) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

                Text(trimmedDisplayName.isEmpty ? trimmedEmail : trimmedDisplayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !trimmedDisplayName.isEmpty,
                   !trimmedDisplayName.localizedCaseInsensitiveContains(trimmedEmail) {
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
    }
}
