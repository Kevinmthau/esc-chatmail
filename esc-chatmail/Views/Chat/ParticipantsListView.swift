import SwiftUI
import Contacts

struct ParticipantsListView: View {
    let conversation: Conversation
    let onCreateNewContact: (Person) -> Void
    let onAddToExistingContact: (Person) -> Void
    let onEditContact: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let participantLoader: ParticipantLoader
    private let currentUserEmail: String

    /// Cached list of other participants to avoid recomputation on every render.
    @State private var cachedOtherParticipants: [ParticipantListItem] = []

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
                ForEach(cachedOtherParticipants) { participant in
                    ParticipantRow(
                        displayName: participant.displayName,
                        email: participant.email,
                        isExistingContact: participant.isExistingContact,
                        contactIdentifier: participant.contactIdentifier,
                        onCreateNewContact: {
                            onCreateNewContact(participant.person)
                        },
                        onAddToExistingContact: {
                            onAddToExistingContact(participant.person)
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
                Task {
                    await updateOtherParticipants()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                Task {
                    await ContactsResolver.shared.invalidateAllCache()
                    await PersonCache.shared.clearCache()
                    await updateOtherParticipants()
                }
            }
        }
    }

    /// Computes the list of other participants (non-current-user).
    /// Uses email normalization to properly match participants.
    @MainActor
    private func updateOtherParticipants() async {
        let otherEmails = participantLoader.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: currentUserEmail
        )
        let otherEmailSet = Set(otherEmails.map { EmailNormalizer.normalize($0) })

        guard let participants = conversation.participants else {
            cachedOtherParticipants = []
            return
        }

        var personsByNormalizedEmail: [String: Person] = [:]
        for participant in participants {
            guard let person = participant.person else { continue }

            let normalizedEmail = EmailNormalizer.normalize(person.email)
            guard otherEmailSet.contains(normalizedEmail),
                  personsByNormalizedEmail[normalizedEmail] == nil else {
                continue
            }

            personsByNormalizedEmail[normalizedEmail] = person
        }

        let resolvedParticipants = await participantLoader.resolveParticipants(for: otherEmails)

        cachedOtherParticipants = resolvedParticipants.compactMap { participant in
            guard let person = personsByNormalizedEmail[EmailNormalizer.normalize(participant.email)] else {
                return nil
            }

            return ParticipantListItem(
                person: person,
                displayName: participant.displayName,
                email: person.email,
                isExistingContact: participant.contactIdentifier != nil,
                contactIdentifier: participant.contactIdentifier
            )
        }
    }
}

private struct ParticipantListItem: Identifiable {
    let person: Person
    let displayName: String
    let email: String
    let isExistingContact: Bool
    let contactIdentifier: String?

    var id: String {
        if let contactIdentifier, !contactIdentifier.isEmpty {
            return "contact:\(contactIdentifier)"
        }

        return "email:\(EmailNormalizer.normalize(email))"
    }
}
