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
/// Ownership passes with the draft, not only with the right to write it. A
/// composer that left the screen saves what it holds through the cleanup
/// gate, behind whatever holds that queue, and a composer created for the
/// chat before that save ran used to load the older stored draft while the
/// save was dropped as stale: the words typed since the last autosave were
/// lost. On the Mac that takes two arrow keys (chat A, B, A). The new
/// composer now takes the draft from the one that left
/// (`withdrawnDraftOwner`, `ChatViewModel.handOverOwedReplyDraft`).
///
/// It also counts the conversation's reply sends that have not made their
/// optimistic message durable yet (`UnpersistedSend`). Until then the stored
/// draft still holds the text being sent (the autosave that ran before the
/// tap), and only the send's own transaction removes it. A composer opened in
/// that window restored that text, so the sent reply reappeared, ready to be
/// sent twice, or was doubled when a failed send handed it over too.
///
/// And it is what the Mac's quit asks about drafts: it makes the saves the
/// on-screen composers' debounce still owes (`flushPresentedDraftsForTermination`),
/// and its `draftWriteTracker` counts every draft write its composers have
/// scheduled, which the quit waits for as it waits for sends
/// (`MacAppDelegate.applicationShouldTerminate`, `AppTerminationWait`).
@MainActor
final class ChatReplyComposerDirectory {
    static let shared = ChatReplyComposerDirectory()

    /// The gated draft writes of this directory's composers
    /// (`ChatViewModel.startReplyDraftSave`, `ChatViewModel.handOffUnsentReply`).
    /// Per directory, so a test's view models never count toward another's.
    let draftWriteTracker: ReplyDraftWriteTracker

    init() {
        draftWriteTracker = ReplyDraftWriteTracker()
    }

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

    private typealias Presentation = (generation: UInt64, composer: () -> ChatViewModel?)

    private var nextGeneration: UInt64 = 0
    /// Held weakly, like the presented composers: an owner whose screen is
    /// gone lives only as long as its queued save or its send.
    private var draftOwners: [NSManagedObjectID: Presentation] = [:]
    private var presentedComposers: [NSManagedObjectID: Presentation] = [:]
    private var unpersistedSendCounts: [NSManagedObjectID: Int] = [:]

    /// Makes `composer` the on-screen composer and the draft owner for the
    /// conversation, superseding any earlier one. Returns its generation.
    func present(_ composer: ChatViewModel, for conversationObjectID: NSManagedObjectID) -> UInt64 {
        nextGeneration &+= 1
        let presentation: Presentation = (nextGeneration, { [weak composer] in composer })
        draftOwners[conversationObjectID] = presentation
        presentedComposers[conversationObjectID] = presentation
        return presentation.generation
    }

    /// The composer left the screen. It stays the draft owner until another
    /// composer for the conversation is presented, so its final save lands.
    func withdraw(generation: UInt64, for conversationObjectID: NSManagedObjectID) {
        guard presentedComposers[conversationObjectID]?.generation == generation else { return }
        presentedComposers[conversationObjectID] = nil
    }

    func ownsDraft(generation: UInt64, for conversationObjectID: NSManagedObjectID) -> Bool {
        draftOwners[conversationObjectID]?.generation == generation
    }

    func presentedComposer(for conversationObjectID: NSManagedObjectID) -> ChatViewModel? {
        presentedComposers[conversationObjectID]?.composer()
    }

    /// The conversation's draft owner, if it has left the screen and no
    /// composer has been presented for the conversation since.
    ///
    /// Asked by a composer about to be presented, before `present` makes it
    /// the owner: this one's final save may not have run yet (see the type
    /// comment). Nil while a composer is on screen. That one is being typed
    /// into, and nothing takes its content from under it.
    func withdrawnDraftOwner(for conversationObjectID: NSManagedObjectID) -> ChatViewModel? {
        guard presentedComposers[conversationObjectID] == nil else { return nil }
        return draftOwners[conversationObjectID]?.composer()
    }

    /// The quit is about to ask whether a draft write is outstanding: each
    /// on-screen composer that still owes the store a save starts it now
    /// (`ChatViewModel.saveReplyDraftChangeForTermination`): a change its
    /// 350 ms debounce has not handed to a save yet, a save that read it and
    /// failed, or files still importing.
    ///
    /// Without this, Cmd-Q, or closing the mailbox window (which quits), within
    /// 350 ms of the last keystroke lost what was typed since the last save.
    /// The debounce cannot be left to fire during the quit's wait: a quit
    /// with nothing outstanding does not wait at all, and while one does,
    /// AppKit runs the main run loop in `NSModalPanelRunLoopMode`, where the
    /// debounce's `RunLoop.main` timer probably does not fire (not measured).
    ///
    /// The saves are the composers' own and keep every guard a save has: each
    /// starts in `startReplyDraftSave`, is made only by a composer on screen,
    /// waits for the cleanup-sensitive gate, and reads the composer there,
    /// where it writes nothing while the composer is sending, when another
    /// composer owns the draft, or for another account. A composer that a
    /// save has read as it is, is left alone: the flush makes the saves the
    /// composers owe sooner and no others. Saved anyway, an empty composer
    /// opened while an earlier screen's reply was still unpersisted would
    /// remove the stored copy of that reply (`hasUnpersistedSend`).
    ///
    /// HONEST SCOPE: in the app that keeps the stored copy only until the
    /// chat's load gives the empty composer an automatic reply target
    /// (`ChatViewModel.initializeReplyingTo`). That is a change, so 350 ms
    /// later the debounce makes the same empty save, as it did before this
    /// flush existed, and so do the composer's disappearance and the scene
    /// leaving `.active` (`ChatView`), which save whatever the composer holds.
    /// The reply is lost only if the process dies before it is persisted: a
    /// send that fails gives it to the open composer, or merges it into the
    /// stored draft (`ChatViewModel.returnUnsentReply`).
    ///
    /// A composer off screen is not asked. It started its save when it left
    /// (`ChatViewModel.composerDidDisappear`), and `draftWriteTracker` still
    /// counts that save if it has not run.
    func flushPresentedDraftsForTermination() {
        let composers = presentedComposers.values.compactMap { $0.composer() }
        for composer in composers {
            composer.saveReplyDraftChangeForTermination()
        }
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
