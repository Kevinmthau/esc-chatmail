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
@MainActor
final class ChatReplyComposerDirectory {
    static let shared = ChatReplyComposerDirectory()

    private var nextGeneration: UInt64 = 0
    private var draftOwnerGenerations: [NSManagedObjectID: UInt64] = [:]
    private var presentedComposers: [NSManagedObjectID: (generation: UInt64, composer: () -> ChatViewModel?)] = [:]

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
}
