import SwiftUI

struct ParticipantRow: View {
    let person: Person
    let onAddContact: () -> Void
    @State private var isExistingContact = false
    private let contactsResolver = ContactsResolver.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName ?? person.email)
                    .font(.body)
                if person.displayName != nil {
                    Text(person.email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isExistingContact {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button(action: onAddContact) {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }
        }
        .task {
            if let match = await contactsResolver.lookup(email: person.email) {
                isExistingContact = match.displayName != nil
            }
        }
    }
}
