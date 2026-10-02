import CoreData

/// Which chat composer is on screen for each conversation, and which one owns
/// the conversation's single durable `ChatReplyDraft`.
///
/// Navigation is not blocked while a reply sends, and the send task retains
/// its `ChatViewModel` until transmission admission, so a view model can
/// outlive its screen. If that send then fails before the optimistic message
/// became durable (or is rolled back later), the send's snapshot is the only
/// copy of the reply. Restored into the off-screen composer, its alert was
/// never shown, and if the chat had been reopened the off-screen model's draft
/// save raced the open one: the open composer, which never loaded the
/// restored text, deleted the draft on its next (empty) save.
///
/// Ownership is a monotonic presentation generation per conversation. The
/// newest presented composer owns the durable draft. An older view model never
/// writes it from its own composer again (`ChatViewModel.saveReplyDraft`); it
/// hands an unsent reply to the presented composer, or merges it into the
/// stored draft when no composer is on screen.
///
/// It also counts the conversation's reply sends that have not made their
/// optimistic message durable yet (`UnpersistedSend`). Until then the stored
/// draft still holds the text being sent (the autosave that ran before the
/// tap), and only the send's own transaction removes it. A composer opened in
/// that window restored that text, so the sent reply reappeared, ready to be
/// sent twice, or was doubled when a failed send handed it over too.
@MainActor
final class ChatReplyComposerDirectory {
    static let shared = ChatReplyComposerDirectory()

    /// One reply send from the tap until its content has a durable owner
    /// again: the optimistic message, the open composer that took it back, or
    /// the stored draft it was merged into. `end()` is idempotent.
    @MainActor
    final class UnpersistedSend {
        private let directory: ChatReplyComposerDirectory
        private let conversationObjectID: NSManagedObjectID
        private var hasEnded = false

        fileprivate init(directory: ChatReplyComposerDirectory, conversationObjectID: NSManagedObjectID) {
            self.directory = directory
            self.conversationObjectID = conversationObjectID
        }

        func end() {
            guard !hasEnded else { return }
            hasEnded = true
            directory.endUnpersistedSend(for: conversationObjectID)
        }
    }

    private var nextGeneration: UInt64 = 0
    private var draftOwnerGenerations: [NSManagedObjectID: UInt64] = [:]
    private var presentedComposers: [NSManagedObjectID: (generation: UInt64, composer: () -> ChatViewModel?)] = [:]
    private var unpersistedSendCounts: [NSManagedObjectID: Int] = [:]

    /// Makes `composer` the on-screen composer and the draft owner for the
    /// conversation, superseding any earlier one. Returns its generation.
    func present(_ composer: ChatViewModel, for conversationObjectID: NSManagedObjectID) -> UInt64 {
        nextGeneration &+= 1
        let generation = nextGeneration
        draftOwnerGenerations[conversationObjectID] = generation
        presentedComposers[conversationObjectID] = (generation, { [weak composer] in composer })
        return generation
    }

    /// The composer left the screen. It stays the draft owner until another
    /// composer for the conversation is presented, so its final save lands.
    func withdraw(generation: UInt64, for conversationObjectID: NSManagedObjectID) {
        guard presentedComposers[conversationObjectID]?.generation == generation else { return }
        presentedComposers[conversationObjectID] = nil
    }

    func ownsDraft(generation: UInt64, for conversationObjectID: NSManagedObjectID) -> Bool {
        draftOwnerGenerations[conversationObjectID] == generation
    }

    func presentedComposer(for conversationObjectID: NSManagedObjectID) -> ChatViewModel? {
        presentedComposers[conversationObjectID]?.composer()
    }

    /// Registers a reply send in its tap turn, before anything awaits.
    func beginUnpersistedSend(for conversationObjectID: NSManagedObjectID) -> UnpersistedSend {
        unpersistedSendCounts[conversationObjectID, default: 0] += 1
        return UnpersistedSend(directory: self, conversationObjectID: conversationObjectID)
    }

    /// Whether the conversation's stored draft may still hold a reply that is
    /// being sent (see the type comment). A composer created meanwhile starts
    /// empty instead of restoring it.
    func hasUnpersistedSend(for conversationObjectID: NSManagedObjectID) -> Bool {
        (unpersistedSendCounts[conversationObjectID] ?? 0) > 0
    }

    fileprivate func endUnpersistedSend(for conversationObjectID: NSManagedObjectID) {
        let remaining = (unpersistedSendCounts[conversationObjectID] ?? 0) - 1
        unpersistedSendCounts[conversationObjectID] = remaining > 0 ? remaining : nil
    }
}
