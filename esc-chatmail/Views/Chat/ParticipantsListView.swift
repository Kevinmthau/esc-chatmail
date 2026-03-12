import SwiftUI

struct ParticipantsListView: View {
    let conversation: Conversation
    let onCreateNewContact: (Person) -> Void
    let onAddToExistingContact: (Person) -> Void
    let onEditContact: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let participantLoader: ParticipantLoader
    private let currentUserEmail: String

    /// Cached list of other participants to avoid recomputation on every render.
    @State private var cachedOtherParticipants: [Person] = []

    @MainActor
    init(
        conversation: Conversation,
        deps: Dependencies? = nil,
        onCreateNewContact: @escaping (Person) -> Void,
        onAddToExistingContact: @escaping (Person) -> Void,
        onEditContact: @escaping (String) -> Void
    ) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.conversation = conversation
        self.onCreateNewContact = onCreateNewContact
        self.onAddToExistingContact = onAddToExistingContact
        self.onEditContact = onEditContact
        self.participantLoader = resolvedDeps.participantLoader
        self.currentUserEmail = resolvedDeps.authSession.userEmail ?? ""
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(cachedOtherParticipants, id: \.email) { person in
                    ParticipantRow(
                        person: person,
                        onCreateNewContact: {
                            onCreateNewContact(person)
                        },
                        onAddToExistingContact: {
                            onAddToExistingContact(person)
                        },
                        onEditContact: { identifier in
                            onEditContact(identifier)
                        }
                    )
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
            .onAppear {
                updateOtherParticipants()
            }
        }
    }

    /// Computes the list of other participants (non-current-user).
    /// Uses email normalization to properly match participants.
    private func updateOtherParticipants() {
        let otherEmails = Set(participantLoader.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail
        ).map { EmailNormalizer.normalize($0) })

        guard let participants = conversation.participants else {
            cachedOtherParticipants = []
            return
        }

        cachedOtherParticipants = participants.compactMap { participant -> Person? in
            guard let person = participant.person else { return nil }
            return otherEmails.contains(EmailNormalizer.normalize(person.email)) ? person : nil
        }
    }
}
