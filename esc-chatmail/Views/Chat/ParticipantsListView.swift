import SwiftUI

struct ParticipantsListView: View {
    let conversation: Conversation
    let onAddContact: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    private let contactsResolver = ContactsResolver.shared
    private let participantLoader = ParticipantLoader.shared

    private var otherParticipants: [Person] {
        let currentUserEmail = AuthSession.shared.userEmail ?? ""
        let otherEmails = Set(participantLoader.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail
        ).map { EmailNormalizer.normalize($0) })

        guard let participants = conversation.participants else { return [] }
        return participants.compactMap { participant -> Person? in
            guard let person = participant.person else { return nil }
            return otherEmails.contains(EmailNormalizer.normalize(person.email)) ? person : nil
        }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(otherParticipants, id: \.email) { person in
                    ParticipantRow(person: person) {
                        onAddContact(person)
                    }
                }
            }
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
