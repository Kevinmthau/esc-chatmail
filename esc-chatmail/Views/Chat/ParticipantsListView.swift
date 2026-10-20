import SwiftUI
import Contacts

struct ParticipantsListView: View {
    let conversation: Conversation
    let onCreateNewContact: (NewContactPrefillPolicy.Prefill) -> Void
    let onAddToExistingContact: (String) -> Void
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
        onAddToExistingContact: @escaping (String) -> Void,
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
                            onAddToExistingContact(participant.email)
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
        guard let participants = conversation.participants else {
            cachedOtherParticipants = []
            return
        }

        // Value copies of each participant's Person, taken before the resolve suspends: a sync can
        // delete a Person while the sheet resolves or stays open, and a row needs only the email
        // and the stored name.
        var storedPersonsByNormalizedEmail: [String: (email: String, displayName: String?)] = [:]
        for participant in participants {
            guard let person = participant.person else { continue }

            let normalizedEmail = EmailNormalizer.normalize(person.email)
            guard !normalizedEmail.isEmpty,
                  storedPersonsByNormalizedEmail[normalizedEmail] == nil else {
                continue
            }

            storedPersonsByNormalizedEmail[normalizedEmail] = (person.email, person.displayName)
        }

        // Resolve from the snapshot the chat header uses (its alias-aware participant list plus
        // the conversation's header and stored names), so a sender the header names is not
        // "Unknown Contact" here and the user's own send-as aliases are not listed.
        let resolvedParticipants: [ParticipantLoader.ResolvedParticipant]
        if let context = conversation.managedObjectContext {
            resolvedParticipants = await participantLoader.resolveParticipants(
                inConversation: conversation.objectID,
                context: context,
                currentUserEmail: currentUserEmail
            )
        } else {
            resolvedParticipants = await participantLoader.resolveParticipants(
                for: participantLoader.extractNonMeParticipants(
                    from: conversation,
                    currentUserEmail: currentUserEmail
                )
            )
        }
        guard !Task.isCancelled else { return }

        cachedOtherParticipants = resolvedParticipants.compactMap { participant in
            guard let person = storedPersonsByNormalizedEmail[EmailNormalizer.normalize(participant.email)] else {
                return nil
            }

            return ParticipantListItem(
                displayName: participant.displayName,
                email: person.email,
                isExistingContact: participant.contactIdentifier != nil,
                contactIdentifier: participant.contactIdentifier,
                newContactPrefill: NewContactPrefillPolicy.prefill(
                    for: participant,
                    storedDisplayName: person.displayName
                )
            )
        }
    }
}

private struct ParticipantListItem: Identifiable {
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
