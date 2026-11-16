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
            .navigationTitle(ParticipantsListPolicy.title(for: listing))
            .inlineNavigationTitle()
            .toolbar {
                // A sheet's placement, not `.trailingBarEdge`: a Mac sheet draws no toolbar
                // item placed there, which left this sheet with no way to close it.
                ToolbarItem(placement: .sheetTrailingBarEdge) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            // On the Mac that Done is the sheet's default button, which Return presses;
            // this makes Escape close the sheet too, as it does the reader's.
            .macSheetClosesOnEscape()
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

    /// Whose rows the sheet lists: the conversation's participants, or for a mailing list the
    /// people who have written to it (`ParticipantsListPolicy`).
    private var listing: ParticipantsListPolicy.Listing {
        ParticipantsListPolicy.listing(conversationType: conversation.conversationType)
    }

    /// Computes the list of other participants (non-current-user).
    /// Uses email normalization to properly match participants.
    @MainActor
    private func updateOtherParticipants() async {
        switch listing {
        case .participants:
            await updateFromParticipantRows()
        case .senders:
            await updateFromMessageSenders()
        }
    }

    @MainActor
    private func updateFromParticipantRows() async {
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

    /// A mailing list's rows: the senders of its received messages. They are read from the
    /// messages, so there is no participant row to match a sender against and no stored Person
    /// name to prefill a new contact from; the row's own name is its From header's.
    @MainActor
    private func updateFromMessageSenders() async {
        // The senders are fetched, and a conversation no longer in a context has no messages
        // to fetch them from.
        guard let context = conversation.managedObjectContext else {
            cachedOtherParticipants = []
            return
        }

        let resolvedSenders = await participantLoader.resolveSenders(
            inConversation: conversation.objectID,
            context: context,
            currentUserEmail: currentUserEmail,
            onProgress: { sendersSoFar in
                // A list with hundreds of senders is resolved a batch at a time, and its
                // first rows are drawn without waiting for its last. A load that was
                // cancelled draws nothing: the rows on screen are the next load's.
                guard !Task.isCancelled else { return }
                cachedOtherParticipants = ParticipantsListPolicy.sendersToDraw(
                    resolvedSoFar: sendersSoFar.map { Self.senderItem($0) },
                    shown: cachedOtherParticipants,
                    id: { $0.id },
                    normalizedAddress: { EmailNormalizer.normalize($0.email) }
                )
            }
        )
        guard !Task.isCancelled else { return }

        cachedOtherParticipants = resolvedSenders.map { Self.senderItem($0) }
    }

    private static func senderItem(_ sender: ParticipantLoader.ResolvedParticipant) -> ParticipantListItem {
        ParticipantListItem(
            displayName: sender.displayName,
            email: sender.email,
            isExistingContact: sender.contactIdentifier != nil,
            contactIdentifier: sender.contactIdentifier,
            newContactPrefill: NewContactPrefillPolicy.prefill(
                for: sender,
                storedDisplayName: nil
            )
        )
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
