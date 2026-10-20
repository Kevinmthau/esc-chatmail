import SwiftUI
import Contacts

struct ParticipantsListView: View {
    let conversation: Conversation
    let onCreateNewContact: (NewContactPrefillPolicy.Prefill) -> Void
    let onAddToExistingContact: (Person) -> Void
    let onEditContact: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let participantLoader: ParticipantLoader
    private let currentUserEmail: String
    private let invalidateContactsCache: () async -> Void
    private let clearPersonCache: () async -> Void

    /// Cached list of other participants to avoid recomputation on every render.
    @State private var cachedOtherParticipants: [ParticipantListItem] = []
    @State private var contactRefreshGeneration = 0

    @MainActor
    init(
        conversation: Conversation,
        chatDependencies: ChatDependencies,
        onCreateNewContact: @escaping (NewContactPrefillPolicy.Prefill) -> Void,
        onAddToExistingContact: @escaping (Person) -> Void,
        onEditContact: @escaping (String) -> Void
    ) {
        self.conversation = conversation
        self.onCreateNewContact = onCreateNewContact
        self.onAddToExistingContact = onAddToExistingContact
        self.onEditContact = onEditContact
        self.participantLoader = chatDependencies.contacts.participantLoader
        self.currentUserEmail = chatDependencies.session.authSession.userEmail ?? ""
        self.invalidateContactsCache = chatDependencies.contacts.invalidateContactsCache
        self.clearPersonCache = chatDependencies.contacts.clearPersonCache
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(cachedOtherParticipants) { participant in
                    ParticipantRow(
                        displayName: participant.displayName,
                        email: participant.email,
                        isExistingContact: participant.isExistingContact,
                        contactIdentifier: participant.contactIdentifier,
                        onCreateNewContact: {
                            onCreateNewContact(participant.newContactPrefill)
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
            .task(id: contactRefreshGeneration) {
                if contactRefreshGeneration > 0 {
                    await invalidateContactsCache()
                    await clearPersonCache()
                    guard !Task.isCancelled else { return }
                }
                await updateOtherParticipants()
            }
            .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                contactRefreshGeneration &+= 1
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

        // Resolve with the conversation's header and stored names, as the chat header does, so a
        // sender the header names is not "Unknown Contact" here (and not prefilled nameless).
        let resolvedParticipants: [ParticipantLoader.ResolvedParticipant]
        if let context = conversation.managedObjectContext {
            resolvedParticipants = await participantLoader.resolveParticipants(
                for: otherEmails,
                inConversation: conversation.objectID,
                context: context
            )
        } else {
            resolvedParticipants = await participantLoader.resolveParticipants(for: otherEmails)
        }
        guard !Task.isCancelled else { return }

        cachedOtherParticipants = resolvedParticipants.compactMap { participant in
            guard let person = personsByNormalizedEmail[EmailNormalizer.normalize(participant.email)] else {
                return nil
            }

            return ParticipantListItem(
                person: person,
                displayName: participant.displayName,
                email: person.email,
                isExistingContact: participant.contactIdentifier != nil,
                contactIdentifier: participant.contactIdentifier,
                newContactPrefill: NewContactPrefillPolicy.prefill(for: participant)
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
    let newContactPrefill: NewContactPrefillPolicy.Prefill

    var id: String {
        if let contactIdentifier, !contactIdentifier.isEmpty {
            return "contact:\(contactIdentifier)"
        }

        return "email:\(EmailNormalizer.normalize(email))"
    }
}
