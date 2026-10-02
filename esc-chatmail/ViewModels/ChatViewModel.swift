import Foundation
import CoreData
import Combine

/// Composer-only state kept separate from the thread's broader presentation state.
///
/// Views that render the reply composer should observe this object directly. Its
/// changes are intentionally not forwarded through `ChatViewModel.objectWillChange`
/// so typing and reply-target updates do not invalidate the message list.
@MainActor
final class ChatComposerState: ObservableObject {
    @Published var replyText: String
    @Published var replyingTo: Message? {
        didSet {
            if let replyingTo {
                replyAnchor = replyingTo
            }
        }
    }
    // Dismissing the quote changes presentation, not the draft's destination.
    private(set) var replyAnchor: Message?
    @Published var attachments: [Attachment]
    @Published var isProcessingAttachments = false
    @Published var recoveredReplyEnvelope: StoredReplyEnvelope?
    @Published var unavailableReplyTargetURI: URL?
    /// True only from the send tap until the optimistic message is durable
    /// (`ChatViewModel.sendReply`): milliseconds, during which the composer's
    /// content lives in the send's snapshot. It blocks a second send, draft
    /// autosave and target changes for that window, not typing.
    @Published private(set) var isSending = false
    private var discardsAttachmentsWhenSendFinishes = false

    init(
        replyText: String = "",
        replyingTo: Message? = nil,
        attachments: [Attachment] = []
    ) {
        self.replyText = replyText
        self.replyingTo = replyingTo
        self.replyAnchor = replyingTo
        self.attachments = attachments
    }

    func replaceReplyTarget(_ message: Message?) {
        replyAnchor = message
        replyingTo = message
    }

    var hasDraftContent: Bool {
        Self.hasDraftContent(
            replyText: replyText,
            hasAttachments: !attachments.isEmpty
        )
    }

    var hasDraftContentPublisher: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest($replyText, $attachments)
            .map { replyText, attachments in
                Self.hasDraftContent(
                    replyText: replyText,
                    hasAttachments: !attachments.isEmpty
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    static func hasDraftContent(
        replyText: String,
        hasAttachments: Bool
    ) -> Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            hasAttachments
    }

    func beginSending() -> Bool {
        guard !isSending, !isProcessingAttachments else { return false }
        isSending = true
        return true
    }

    func finishSending() {
        isSending = false
        if discardsAttachmentsWhenSendFinishes {
            discardsAttachmentsWhenSendFinishes = false
            discardUnsentAttachments()
        }
    }

    func requestUnsentAttachmentDiscard() {
        guard isSending else {
            discardUnsentAttachments()
            return
        }
        discardsAttachmentsWhenSendFinishes = true
    }

    func discardUnsentAttachments() {
        let discardedAttachments = attachments.filter { attachment in
            attachment.managedObjectContext != nil && !attachment.isDeleted && attachment.message == nil
        }
        attachments.removeAll()

        for attachment in discardedAttachments {
            if attachment.isLocalAttachment {
                AttachmentPaths.deleteFile(at: attachment.localURL)
                AttachmentPaths.deleteFile(at: attachment.previewURL)
            }

            attachment.managedObjectContext?.delete(attachment)
        }
    }
}

/// ViewModel for ChatView - manages chat state and message operations
@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var destination: ChatDestination?
    @Published var resolvedDisplayName: String?
    @Published var effectiveParticipantCount: Int?
    @Published var sendErrorAlert: ChatSendErrorAlert?

    // MARK: - Composer State

    let composerState = ChatComposerState()

    /// Source-compatible access for existing callers. Composer UI should observe
    /// `composerState` directly rather than the full chat view model.
    var replyText: String {
        get { composerState.replyText }
        set { composerState.replyText = newValue }
    }

    /// Source-compatible access for existing callers. Composer UI should observe
    /// `composerState` directly rather than the full chat view model.
    var replyingTo: Message? {
        get { composerState.replyingTo }
        set { composerState.replyingTo = newValue }
    }

    // MARK: - Composed Services

    var contactManager: ChatContactManager

    // MARK: - Dependencies

    let conversation: Conversation
    let messageActions: MessageActions
    private let outboundMessageCoordinator: any OutboundMessageCoordinating
    private let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder
    private let outboundReplyContextBuilder: OutboundReplyContextBuilder
    private let composeForwardModeContextBuilder: ComposeForwardModeContextBuilder

    private let authSession: AuthSession
    private let htmlContentHandler: HTMLContentHandler
    private let participantLoader: ParticipantLoader
    private let viewContext: NSManagedObjectContext
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext?
    private let conversationDisplayNameHint: String?
    private let replyOptimisticConversation: OptimisticConversationReference
    private let contactsResolver: any ContactsResolving
    private var cancellables = Set<AnyCancellable>()
    private let draftStore: ChatReplyDraftStore
    private let draftAccountEmail: String?
    private let tokenManager: any TokenManagerProtocol
    private var tokenPrewarmTask: Task<Void, Never>?
    private let conversationMutationSerializer: ConversationRollupMutationSerializer
    @Published private(set) var draftRestoreFailed = false
    private let composerDirectory: ChatReplyComposerDirectory
    /// This view model's presentation in `composerDirectory`. Only the newest
    /// presentation for the conversation writes its durable draft.
    private var composerPresentationGeneration: UInt64 = 0
    /// Unsent replies waiting for the cleanup gate to merge them into the
    /// stored draft (`handOffUnsentReply`), with the text this composer
    /// received after the tap and the send registration the merge ends.
    private var unsentRepliesAwaitingDraftMerge: [(
        snapshot: ChatReplySendSnapshot,
        typedSinceSend: String,
        notice: UnsentReplyNotice,
        unpersistedSend: ChatReplyComposerDirectory.UnpersistedSend?
    )] = []
    /// The screen went away while a send held `isSending`, so its save was
    /// skipped and anything typed since the tap exists only here. The send's
    /// release saves it or hands it on (`saveComposerLeftWhileSending`).
    private var savesComposerWhenSendReleases = false

    // MARK: - Task Management

    private let taskManager = ViewModelTaskManager()
    private let prefetchTaskManager = ViewModelTaskManager()

    var isEffectivelyOneToOneConversation: Bool {
        if conversation.conversationType == .list {
            return false
        }

        if let effectiveParticipantCount {
            return effectiveParticipantCount <= 1
        }

        return conversation.conversationType == .oneToOne
    }

    var displayNameForNavigation: String? {
        if conversation.conversationType == .list,
           let storedDisplayName = conversation.displayName?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedDisplayName.isEmpty {
            return storedDisplayName
        }

        return resolvedDisplayName
    }

    var emailReaderRoute: EmailReaderRoute? {
        guard case .emailReader(let route) = destination else {
            return nil
        }
        return route
    }

    // MARK: - Initialization

    init(
        conversation: Conversation,
        chatDependencies: ChatDependencies,
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared,
        composerDirectory: ChatReplyComposerDirectory? = nil
    ) {
        if conversation.objectID.isTemporaryID {
            try? chatDependencies.storage.viewContext.obtainPermanentIDs(for: [conversation])
        }
        self.conversation = conversation
        self.authSession = chatDependencies.session.authSession
        self.htmlContentHandler = chatDependencies.content.htmlContentHandler
        self.participantLoader = chatDependencies.contacts.participantLoader
        self.viewContext = chatDependencies.storage.viewContext
        self.draftStore = ChatReplyDraftStore(context: chatDependencies.storage.viewContext)
        self.draftAccountEmail = chatDependencies.session.authSession.userEmail
        self.tokenManager = chatDependencies.session.tokenManager
        self.conversationMutationSerializer = conversationMutationSerializer
        self.composerDirectory = composerDirectory ?? .shared
        self.conversationObjectID = conversation.objectID
        self.conversationContext = conversation.managedObjectContext
        self.conversationDisplayNameHint = conversation.displayName
        self.replyOptimisticConversation = .existingConversation(
            ConversationReference(objectID: conversation.objectID)
        )
        self.contactsResolver = chatDependencies.contacts.contactsResolver
        self.messageActions = chatDependencies.messaging.messageActions
        self.outboundMessageCoordinator = chatDependencies.messaging.outboundMessageCoordinator
        self.outboundAttachmentContextBuilder = chatDependencies.messaging.outboundAttachmentContextBuilder
        self.outboundReplyContextBuilder = chatDependencies.messaging.outboundReplyContextBuilder
        self.composeForwardModeContextBuilder = chatDependencies.messaging.composeForwardModeContextBuilder
        self.contactManager = chatDependencies.contacts.makeChatContactManager()

        // Forward child observable changes to trigger view updates
        forwardChanges(from: contactManager, storing: &cancellables)
        restoreReplyDraft()
        composerState.objectWillChange
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleReplyDraftSave() }
            .store(in: &cancellables)
        // Created for a screen that is about to show it: from here on this
        // composer owns the conversation's draft, superseding any view model
        // that a still-running send keeps alive for a screen that is gone.
        composerPresentationGeneration = self.composerDirectory.present(self, for: conversationObjectID)
    }

    // MARK: - Message Actions

    /// Marks all unread messages in the conversation as read
    /// Uses batch operation to prevent race condition with new messages arriving during marking
    func markConversationAsRead(messageObjectIDs: [NSManagedObjectID]) {
        let messageActions = self.messageActions
        let conversationID = conversation.objectID
        taskManager.runDetached("markConversationAsRead-\(UUID().uuidString)") {
            // Use batch operation for atomic update - prevents race condition
            await messageActions.markMessagesAsReadBatch(messageIDs: messageObjectIDs, conversationID: conversationID)
        }
    }

    func markConversationAsReadIfNeeded() {
        let unreadMessageIDs = messageActions.snapshotUnreadInboxMessageObjectIDs(
            conversationID: conversation.id
        )
        guard !unreadMessageIDs.isEmpty else { return }
        markConversationAsRead(messageObjectIDs: unreadMessageIDs)
    }

    func markUnreadInboxMessagesAsReadIfNeeded(messageObjectIDs: [NSManagedObjectID]) {
        let unreadMessageIDs = messageActions.snapshotUnreadInboxMessageObjectIDs(
            messageObjectIDs: messageObjectIDs
        )
        guard !unreadMessageIDs.isEmpty else { return }
        markConversationAsRead(messageObjectIDs: unreadMessageIDs)
    }

    func latestVisibleMessage() -> Message? {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.predicate = MessagePredicates.visibleInChat(conversation: conversation)
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.includesPendingChanges = true
        return try? viewContext.fetch(request).first
    }

    func toggleMessageRead(_ message: Message) {
        let messageID = message.objectID
        taskManager.run("toggleRead-\(messageID)") { [weak self] in
            guard let self = self else { return }
            if message.isUnread {
                await messageActions.markAsRead(message: message)
            } else {
                await messageActions.markAsUnread(message: message)
            }
        }
    }

    func archiveMessage(_ message: Message) {
        let messageID = message.objectID
        taskManager.run("archiveMessage-\(messageID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.archive(message: message)
        }
    }

    func archiveConversation() {
        taskManager.run("archiveConversation") { [weak self] in
            guard let self = self else { return }
            await messageActions.archiveConversation(conversation: conversation)
        }
    }

    func starMessage(_ message: Message) {
        let messageID = message.objectID
        taskManager.run("starMessage-\(messageID)") { [weak self] in
            guard let self = self else { return }
            await messageActions.star(message: message)
        }
    }

    // MARK: - Conversation Settings

    func reportSpam() {
        taskManager.run("reportSpam") { [weak self] in
            guard let self = self else { return }
            await messageActions.reportSpamConversation(conversation: conversation)
        }
    }

    // MARK: - Reply Actions

    private var manuallySelectedReplyTargetID: NSManagedObjectID?
    /// The target as an automatic pass (load, sync arrival, the release-time
    /// re-evaluation) last moved it. A target still equal to it was not
    /// changed by the user, which `restoreUnsentReply` needs to tell apart.
    private var lastAutomaticReplyTarget: ChatReplySendSnapshot.Target?

    func setReplyingTo(_ message: Message) {
        guard !composerState.isSending,
              isValidReplyTarget(message) else { return }
        manuallySelectedReplyTargetID = message.objectID
        composerState.recoveredReplyEnvelope = nil
        composerState.unavailableReplyTargetURI = nil
        replyingTo = message
    }

    func setReplyingTo(messageObjectID: NSManagedObjectID) {
        guard let message = resolveMessage(with: messageObjectID) else { return }
        setReplyingTo(message)
    }

    /// Sets the initial replyingTo message when the conversation loads
    func initializeReplyingTo(lastMessage: Message?) {
        recordingAutomaticReplyTargetChange {
            initializeAutomaticReplyTarget(lastMessage: lastMessage)
        }
    }

    private func initializeAutomaticReplyTarget(lastMessage: Message?) {
        guard !composerState.isSending,
              !composerState.hasDraftContent,
              composerState.replyAnchor == nil,
              composerState.recoveredReplyEnvelope == nil,
              composerState.unavailableReplyTargetURI == nil,
              let lastMessage else { return }
        if let target = automaticReplyTarget(preferring: lastMessage) {
            replyingTo = target
            return
        }
        // The newest row can be one of the user's own sends that is not a
        // target (sending, not sent, delivery unknown, or awaiting its echo).
        // Leaving the target nil read as "the user cleared it", so it stayed
        // nil for the session and the next reply lost its quote.
        replyingTo = newestValidReplyTarget()
    }

    /// `lastMessage` when it is a valid automatic target, except that the
    /// user's own message yields to the other side's newest valid one.
    ///
    /// An own target quoted the user's previous reply back at the other
    /// person and set In-Reply-To to it. Own messages remain targets only in
    /// a conversation without a valid inbound target: a note-to-self, or a
    /// chat the user started that has no reply yet.
    private func automaticReplyTarget(preferring lastMessage: Message) -> Message? {
        guard isValidReplyTarget(lastMessage) else { return nil }
        guard lastMessage.isFromMe else { return lastMessage }
        return newestValidInboundReplyTarget() ?? lastMessage
    }

    /// Newest visible message that is a valid automatic reply target,
    /// preferring the other side's messages over the user's own (see
    /// `automaticReplyTarget(preferring:)`).
    private func newestValidReplyTarget() -> Message? {
        newestValidInboundReplyTarget() ?? newestValidVisibleReplyTarget()
    }

    /// Newest visible message that is a valid reply target, looking past the
    /// few newest rows that can be the user's own unfinished sends.
    private func newestValidVisibleReplyTarget() -> Message? {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.predicate = MessagePredicates.visibleInChat(conversation: conversation)
        request.fetchLimit = 20
        request.includesPendingChanges = true
        let candidates = (try? viewContext.fetch(request)) ?? []
        return candidates.first { isValidReplyTarget($0) }
    }

    /// Newest visible message from someone other than the user that is a
    /// valid reply target. `nil` means the conversation has no inbound target,
    /// which is what lets the user's own messages become automatic targets.
    private func newestValidInboundReplyTarget() -> Message? {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            MessagePredicates.visibleInChat(conversation: conversation),
            NSPredicate(format: "isFromMe == NO")
        ])
        request.fetchLimit = 20
        request.includesPendingChanges = true
        let candidates = (try? viewContext.fetch(request)) ?? []
        return candidates.first { isValidReplyTarget($0) }
    }

    func discardUnsentReplyAttachments() {
        composerState.requestUnsentAttachmentDiscard()
    }

    /// Keeps the reply target anchored to this conversation as rows change.
    ///
    /// A legacy message can move to a List-Id conversation while this chat is
    /// open. For an idle automatic target, use the replacement even when it has
    /// the same subject. Active drafts retain their target for validation. List chats also
    /// advance across Gmail threads whose subjects happen to match.
    ///
    /// An idle automatic target never advances onto the user's own message
    /// while the other side has a valid target, and an own target (chosen only
    /// because no inbound target existed) yields to the first inbound one.
    func updateReplyingToIfNewSubject(lastMessage: Message?) {
        guard !composerState.isSending else { return }
        recordingAutomaticReplyTargetChange {
            reconcileAutomaticReplyTarget(lastMessage: lastMessage)
        }
    }

    /// Runs an automatic target pass and remembers where it left the target
    /// if it moved it. Only moves are recorded: recording an unchanged target
    /// would bless a user's pick (which automatic passes never move) as
    /// automatic.
    private func recordingAutomaticReplyTargetChange(_ pass: () -> Void) {
        let before = currentReplyTarget()
        pass()
        let after = currentReplyTarget()
        if !after.hasSameIdentity(as: before) {
            lastAutomaticReplyTarget = after
        }
    }

    /// The body of `updateReplyingToIfNewSubject` without its in-flight-send
    /// freeze, so `sendReply` can re-evaluate once its send has returned.
    private func reconcileAutomaticReplyTarget(lastMessage: Message?) {
        // If user cleared replyingTo (tapped X), don't auto-update
        guard let currentReplyingTo = replyingTo else { return }

        // A selected message or an active draft owns its destination. If sync
        // invalidates that target, send validation keeps the draft for recovery.
        guard !composerState.hasDraftContent,
              manuallySelectedReplyTargetID != currentReplyingTo.objectID else { return }

        guard isValidReplyTarget(currentReplyingTo) else {
            composerState.replaceReplyTarget(lastMessage.flatMap { automaticReplyTarget(preferring: $0) })
            return
        }

        // The sync echo of the user's own reply carries "Re: <subject>", so
        // the subject comparison below read it as a new subject and moved the
        // target onto it. The other person's next "Re:" reply then matched
        // that subject and never moved it back: later replies quoted the
        // user's own message and set In-Reply-To to it. Do not fix this by
        // normalizing "Re:" prefixes; that would also freeze the target when
        // the other person replies "Re: X".
        //
        // Compare against the automatic candidate, not the newest row itself.
        // One sync can save a newer inbound message together with an even
        // newer own echo. Refusing on the echo alone never adopted the inbound
        // message, and no later collection change delivers it.
        guard let lastMessage,
              let candidate = automaticReplyTarget(preferring: lastMessage) else { return }

        if candidate.isFromMe {
            // No inbound target exists (a note-to-self, or an unanswered chat
            // the user started): own messages advance like any other. A valid
            // inbound target that the candidate fetch missed still never
            // yields to the user's own message.
            guard currentReplyingTo.isFromMe else { return }
        } else if currentReplyingTo.isFromMe {
            // The own target was only a fallback for a conversation with no
            // inbound target. Follow the other person once they write, even
            // when their reply repeats the own target's "Re:" subject.
            replyingTo = candidate
            return
        }

        // List conversations can combine multiple Gmail threads that happen to
        // share a subject. Follow the newest thread so reply metadata and quoted
        // content do not stay anchored to an older list post.
        let currentSubject = currentReplyingTo.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newSubject = candidate.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let listThreadChanged =
            conversation.conversationType == .list &&
            !candidate.gmThreadId.isEmpty &&
            currentReplyingTo.gmThreadId != candidate.gmThreadId

        if currentSubject != newSubject || listThreadChanged {
            replyingTo = candidate
        }
    }

    func setMessageToForward(_ message: Message) {
        do {
            let context = try composeForwardModeContextBuilder.build(
                input: makeForwardModeInput(message)
            )
            destination = .forwardCompose(context)
        } catch {
            Log.error("Failed to prepare forward compose context", category: .message, error: error)
            sendErrorAlert = ChatSendErrorAlert(
                title: "Couldn’t Forward Message",
                message: error.localizedDescription
            )
        }
    }

    func setMessageToForward(messageObjectID: NSManagedObjectID) {
        guard let message = resolveMessage(with: messageObjectID) else { return }
        setMessageToForward(message)
    }

    func openEmailReader(
        for messageID: NSManagedObjectID,
        source: EmailReaderOpenSource,
        initialMode: EmailReaderMode = .original
    ) {
        guard let message = resolveMessage(with: messageID) else { return }
        destination = .emailReader(
            EmailReaderRoute(
                messageObjectID: message.objectID,
                conversationObjectID: message.conversation?.objectID ?? conversationObjectID,
                source: source,
                initialMode: initialMode
            )
        )
    }

    func dismissDestination() {
        if case .emailReader = destination {
            Log.info("Dismissed full message view", category: .ui)
        }
        destination = nil
    }

    /// Sends the composer's reply the way iMessage does: the field empties in
    /// the tap's main-actor turn and the composer is released for the next
    /// reply as soon as the optimistic message is durable.
    ///
    /// `isSending` spans only tap → `onOptimisticMessagePersisted`
    /// (milliseconds). Until then `snapshot` is the only owner of the content,
    /// so every failure before it restores the snapshot (merged with anything
    /// typed meanwhile) and shows the alert, in whichever composer is on
    /// screen (`returnUnsentReply`). After it the optimistic graph and
    /// its `OutboundSendMutationRecord` own the content: a send-path failure
    /// before the barrier is retained as a "Not sent" bubble with Edit and
    /// resend (`.retainAsNotSent`), with no alert and no restore. The only
    /// later throw is a rollback (cancellation or account teardown), which
    /// deleted the bubble, so the snapshot is restored then too.
    ///
    /// The returned result still represents transmission admission, which the
    /// transcript coordinator uses for its final anchoring pass.
    func sendReply(
        onOptimisticMessagePersisted: @escaping @MainActor (OutboundMessageResult) -> Void = { _ in }
    ) async -> OutboundMessageResult? {
        guard authSession.userEmail == draftAccountEmail else { return nil }
        guard !draftRestoreFailed else {
            sendErrorAlert = ChatSendErrorAlert(title: "Couldn’t Restore Draft", message: "Reopen this chat to try again, or explicitly discard the saved draft before sending a new reply.")
            return nil
        }
        guard composerState.unavailableReplyTargetURI == nil else {
            sendErrorAlert = ChatSendErrorAlert(message: "The original reply target is no longer available. Select a message to reply to, or clear the unavailable target.")
            return nil
        }
        let trimmedReplyText = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerState.attachments
        guard !trimmedReplyText.isEmpty || !attachments.isEmpty else { return nil }
        guard composerState.beginSending() else { return nil }
        // Cleared once the optimistic message is persisted: from then on a
        // newer send may own `isSending`, and this call must not end it.
        var ownsComposer = true
        defer {
            // Runs after any restore below, so the save persists the restored
            // content rather than the cleared composer.
            if ownsComposer { composerState.finishSending() }
            scheduleReplyDraftSave()
        }

        guard !isConversationDrained else {
            Log.warning(
                "Blocked reply send because the anchored conversation drained during rerouting",
                category: .message
            )
            sendErrorAlert = ChatSendErrorAlert(
                message: GmailSendService.SendError.replyConversationUnavailable.localizedDescription
            )
            return nil
        }

        let request: OutboundMessageRequest
        do {
            if let target = composerState.replyAnchor, target.objectID.isTemporaryID {
                try viewContext.obtainPermanentIDs(for: [target])
            }
            let attachmentContexts = try outboundAttachmentContextBuilder.buildSendAttachments(
                from: attachments
            )
            request = .reply(
                .init(
                    context: outboundReplyContextBuilder.build(
                        conversationObjectID: conversation.objectID,
                        replyingToMessageObjectID: composerState.replyAnchor?.objectID,
                        optimisticConversation: replyOptimisticConversation,
                        includesQuotedMessage: replyingTo != nil
                    ),
                    body: trimmedReplyText,
                    attachments: attachmentContexts,
                    retryMetadata: composerState.recoveredReplyEnvelope?.metadata(
                        resolver: outboundReplyContextBuilder.replyQuotedHTMLResolver
                    ),
                    preTransmissionFailureDisposition: .retainAsNotSent
                )
            )
        } catch {
            Log.error("Failed to prepare reply send", category: .message, error: error)
            sendErrorAlert = ChatSendErrorAlert(message: error.localizedDescription)
            return nil
        }

        // Still the tap's main-actor turn: no await has run, so the field
        // empties in the same frame the send button was tapped. The request
        // above already captured the body, so nothing typed from here on can
        // change what is sent. Keep the reply target so another message in
        // this chat retains its subject and threading headers while the
        // sent-message echo arrives; a recovered envelope serves the same
        // purpose when its original target is no longer available locally.
        //
        // HONEST SCOPE: the field stays focused, and a plain SwiftUI text
        // field cannot commit pending input first. An uncommitted IME
        // composition (marked CJK text) is not in the binding yet: it is left
        // out of the sent body and stays in the field after this clear.
        let snapshot = ChatReplySendSnapshot(
            replyText: replyText,
            attachments: attachments,
            target: currentReplyTarget()
        )
        // The stored draft still holds this text (the autosave before the
        // tap) until the optimistic transaction removes it. A chat reopened
        // meanwhile must not load it as a draft (`restoreReplyDraft`).
        let unpersistedSend = composerDirectory.beginUnpersistedSend(for: conversationObjectID)
        replyText = ""
        composerState.attachments = []

        let result: OutboundMessageResult?
        do {
            result = try await outboundMessageCoordinator.send(
                request,
                onOptimisticMessagePersisted: { [self] optimisticResult in
                    // Release in the same main-actor turn that publishes the
                    // bubble: the optimistic save already removed the durable
                    // draft, and a gate-queued autosave reading the cleared
                    // composer can only write an empty (or newer) draft.
                    ownsComposer = false
                    unpersistedSend.end()
                    composerState.finishSending()
                    reevaluateReplyTargetAfterSend()
                    saveComposerLeftWhileSending()
                    onOptimisticMessagePersisted(optimisticResult)
                }
            )
        } catch {
            Log.error("Failed to prepare reply send", category: .message, error: error)
            returnUnsentReply(snapshot, notice: .notSent(error.localizedDescription), unpersistedSend: unpersistedSend)
            return nil
        }
        guard let result else {
            returnUnsentReply(snapshot, notice: .notSent(nil), unpersistedSend: unpersistedSend)
            return nil
        }
        // A coordinator always reports persistence before success; this only
        // keeps a missed callback from holding back draft restores.
        unpersistedSend.end()
        return result
    }

    /// The release half of `composerDidDisappear` for a screen that left
    /// while this composer was sending: its save then skipped (`isSending`),
    /// so text typed after the tap was in no draft.
    private func saveComposerLeftWhileSending() {
        guard savesComposerWhenSendReleases else { return }
        savesComposerWhenSendReleases = false
        if isComposerPresented {
            // The same screen came back.
            scheduleReplyDraftSave()
        } else if composerDirectory.ownsDraft(generation: composerPresentationGeneration, for: conversationObjectID) {
            // Off screen `scheduleReplyDraftSave` is a no-op; this is the
            // save the disappearance could not make.
            taskManager.run("saveReplyDraft") { [self] in
                await saveReplyDraft()
            }
        } else if composerState.hasDraftContent {
            // The chat was opened again since; that composer owns the draft
            // and never saw this text.
            let typed = ChatReplySendSnapshot(
                replyText: replyText,
                attachments: composerState.attachments,
                target: currentReplyTarget()
            )
            replyText = ""
            composerState.attachments = []
            handOffUnsentReply(typed, notice: .none, unpersistedSend: nil)
        }
    }

    /// Re-evaluates the reply target once a send has released the composer.
    ///
    /// A context-menu Reply is one-shot, like an iMessage inline reply. Kept
    /// selected, it silently governed every later reply in the session (a
    /// list reply went to the old post's thread and audience). The send's
    /// request was built at tap, so this cannot change what was sent. It runs
    /// at release, not at admission: from release on the user can pick the
    /// next reply's target, and a later pass would clear that choice. A newer
    /// message that arrived while the send froze the target fires no further
    /// collection change, so re-evaluate once here. A failed send keeps its
    /// selection (`restoreUnsentReply`).
    private func reevaluateReplyTargetAfterSend() {
        recordingAutomaticReplyTargetChange {
            let sentManualSelection = manuallySelectedReplyTargetID != nil
            manuallySelectedReplyTargetID = nil
            if sentManualSelection {
                replaceSentManualReplyTarget()
            } else {
                reconcileAutomaticReplyTarget(lastMessage: newestValidReplyTarget())
            }
        }
    }

    private func currentReplyTarget() -> ChatReplySendSnapshot.Target {
        ChatReplySendSnapshot.Target(
            replyingTo: composerState.replyingTo,
            replyAnchor: composerState.replyAnchor,
            recoveredReplyEnvelope: composerState.recoveredReplyEnvelope,
            manuallySelectedReplyTargetID: manuallySelectedReplyTargetID
        )
    }

    /// Gives a reply that never became a durable send (or was rolled back)
    /// back to whichever composer the user can see.
    ///
    /// Navigation stays available during a send, and the send task keeps
    /// this view model alive after its screen is gone. Restoring into an
    /// off-screen composer hid the alert, and its draft save raced the
    /// reopened chat's composer, which then deleted the restored draft on its
    /// own empty save. See `ChatReplyComposerDirectory`.
    private func returnUnsentReply(
        _ snapshot: ChatReplySendSnapshot,
        notice: UnsentReplyNotice,
        unpersistedSend: ChatReplyComposerDirectory.UnpersistedSend
    ) {
        guard isComposerPresented else {
            handOffUnsentReply(snapshot, notice: notice, unpersistedSend: unpersistedSend)
            return
        }
        // Back on screen: the restore keeps what was typed since the tap, and
        // `sendReply`'s deferred save persists it.
        savesComposerWhenSendReleases = false
        restoreUnsentReply(snapshot)
        unpersistedSend.end()
        if case .notSent(let alertMessage?) = notice {
            sendErrorAlert = ChatSendErrorAlert(message: alertMessage)
        }
    }

    /// How a hand-off is announced to the composer that takes it.
    private enum UnsentReplyNotice {
        /// Text typed here after a send tap that did persist: nothing failed.
        case none
        /// A reply that was not sent, with the failure's message if any.
        case notSent(String?)
    }

    /// This screen is gone: the chat's open composer takes the reply, or,
    /// with none open, the stored draft does (merged, under the cleanup gate
    /// like every draft write, and re-checking for a composer opened since).
    ///
    /// Text typed into this composer after the tap whose save the screen's
    /// disappearance skipped (`savesComposerWhenSendReleases`) goes with it,
    /// after the reply's own text, and leaves this composer: nothing off
    /// screen saves it, and this composer must not write it again. Text the
    /// disappearance did save is already in the stored draft (or the reopened
    /// composer that loaded it) and is not sent along a second time.
    ///
    /// `unpersistedSend` ends only once the content has its new owner, so a
    /// chat opened while the merge waits for the gate does not also load the
    /// stored copy and then receive the reply a second time.
    private func handOffUnsentReply(
        _ snapshot: ChatReplySendSnapshot,
        notice: UnsentReplyNotice,
        unpersistedSend: ChatReplyComposerDirectory.UnpersistedSend?
    ) {
        var typedSinceSend = ""
        if savesComposerWhenSendReleases {
            savesComposerWhenSendReleases = false
            typedSinceSend = replyText
            replyText = ""
        }
        if let presented = composerDirectory.presentedComposer(for: conversationObjectID),
           presented !== self {
            presented.adoptUnsentReply(snapshot, typedSinceSend: typedSinceSend, notice: notice)
            unpersistedSend?.end()
            return
        }
        unsentRepliesAwaitingDraftMerge.append((snapshot, typedSinceSend, notice, unpersistedSend))
        taskManager.run("mergeUnsentReply-\(UUID().uuidString)") { [self] in
            do {
                try await conversationMutationSerializer.performThrowingCleanupSensitiveMutation { [self] in
                    try await mergeUnsentRepliesIntoDraftWithoutCleanupInterleaving()
                }
            } catch {
                Log.error("Failed to keep an unsent reply as a draft", category: .message, error: error)
            }
        }
    }

    private func mergeUnsentRepliesIntoDraftWithoutCleanupInterleaving() throws {
        let replies = unsentRepliesAwaitingDraftMerge
        unsentRepliesAwaitingDraftMerge.removeAll()
        defer { replies.forEach { $0.unpersistedSend?.end() } }
        guard authSession.userEmail == draftAccountEmail else { return }
        for reply in replies {
            if let presented = composerDirectory.presentedComposer(for: conversationObjectID),
               presented !== self {
                presented.adoptUnsentReply(reply.snapshot, typedSinceSend: reply.typedSinceSend, notice: reply.notice)
                continue
            }
            guard conversation.managedObjectContext === viewContext, !conversation.isDeleted else {
                throw ReplyDraftPersistenceError.conversationUnavailable
            }
            try draftStore.saveMergingUnsentReply(
                reply.snapshot.storedDraft,
                attachments: reply.snapshot.attachments,
                typedAfterUnsent: reply.typedSinceSend,
                conversationID: conversation.id
            )
        }
    }

    /// Takes a reply that another view model for this conversation, whose
    /// screen is gone, could not send (or text it received after a send tap).
    private func adoptUnsentReply(
        _ snapshot: ChatReplySendSnapshot,
        typedSinceSend: String,
        notice: UnsentReplyNotice
    ) {
        restoreUnsentReply(ChatReplySendSnapshot(
            replyText: ChatReplyRestorePolicy.restoredText(
                unsentText: snapshot.replyText,
                typedSinceSend: typedSinceSend
            ),
            attachments: snapshot.attachments,
            target: snapshot.target
        ))
        if case .notSent(let alertMessage) = notice {
            sendErrorAlert = ChatSendErrorAlert(
                title: "Reply Not Sent",
                message: alertMessage ?? "Your reply was not sent. It is back in the reply field."
            )
        }
        scheduleReplyDraftSave()
    }

    /// Puts a reply that never became a durable send back into the composer.
    ///
    /// Text typed since the tap is kept after the unsent text, and attachments
    /// added since are kept after the unsent ones. The target comes back
    /// unless the user steered the composer since: a target picked or cleared
    /// by hand, or typed text, wins. An automatic move does not count. The
    /// composer releases at persistence, so sync can move an idle target
    /// (a newer list post, a new subject) while the send is in preflight;
    /// counting that as a change restored the text onto the new target, in a
    /// list chat another post's thread and audience.
    private func restoreUnsentReply(_ snapshot: ChatReplySendSnapshot) {
        let typedSinceSend = composerState.hasDraftContent
        let current = currentReplyTarget()
        let targetIsUntouched = current.hasSameIdentity(as: snapshot.target) || (
            !typedSinceSend &&
                lastAutomaticReplyTarget.map { current.hasSameIdentity(as: $0) } == true
        )
        replyText = ChatReplyRestorePolicy.restoredText(
            unsentText: snapshot.replyText,
            typedSinceSend: replyText
        )
        composerState.attachments = ChatReplyRestorePolicy.restoredAttachments(
            unsent: snapshot.attachments,
            addedSinceSend: composerState.attachments
        )
        guard targetIsUntouched, snapshot.target.isRestorable else { return }
        composerState.replaceReplyTarget(snapshot.target.replyAnchor)
        if snapshot.target.replyingTo == nil { replyingTo = nil }
        composerState.recoveredReplyEnvelope = snapshot.target.recoveredReplyEnvelope
        manuallySelectedReplyTargetID = snapshot.target.manuallySelectedReplyTargetID
    }

    /// Hands the composer back to the automatic target after a context-menu
    /// Reply was sent.
    ///
    /// The subject comparison in `reconcileAutomaticReplyTarget` cannot do
    /// this: in a Gmail thread the older message the user picked and the
    /// newest one both read "Re: X", so it refused to move and the selection
    /// stayed as the automatic target for the rest of the session.
    private func replaceSentManualReplyTarget() {
        // A draft typed while the send was in flight owns its destination,
        // as in `reconcileAutomaticReplyTarget`.
        guard !composerState.hasDraftContent,
              let automaticTarget = newestValidReplyTarget() else {
            reconcileAutomaticReplyTarget(lastMessage: newestValidReplyTarget())
            return
        }
        // Dismissing the quote kept the selection as the hidden destination
        // (`replyAnchor`), so later unquoted replies silently took its thread
        // and, in a list chat, its audience. Move the destination as well,
        // and keep the quote dismissed.
        let quoteWasDismissed = replyingTo == nil
        composerState.replaceReplyTarget(automaticTarget)
        if quoteWasDismissed { replyingTo = nil }
    }

    // MARK: - Durable reply drafts and failed-send recovery

    /// Retain the screen state until its lifecycle-triggered save finishes, even
    /// after navigation releases the view. Repeated requests replace older work.
    ///
    /// Off screen this is a no-op: `composerDidDisappear` already scheduled
    /// the save of what the user left, and a later request (the send's
    /// deferred save at admission, a debounced keystroke) would replace it
    /// with a stale composer. An empty one removed the draft a reopened chat
    /// had saved since.
    func scheduleReplyDraftSave() {
        guard isComposerPresented else { return }
        taskManager.run("saveReplyDraft") { [self] in
            await saveReplyDraft()
        }
    }

    /// Whether this composer is the one on screen for its conversation.
    private var isComposerPresented: Bool {
        composerDirectory.presentedComposer(for: conversationObjectID) === self
    }

    /// `ChatView.onAppear`. The view model is presented at creation; this
    /// only matters if the same screen comes back after disappearing.
    func composerDidAppear() {
        guard !isComposerPresented else { return }
        composerPresentationGeneration = composerDirectory.present(self, for: conversationObjectID)
    }

    /// `ChatView.onDisappear`: saves what the user left, then stops treating
    /// this composer as the visible one. It keeps owning the stored draft
    /// until the chat is opened again, so that save still lands; a reply that
    /// fails later is handed off instead of restored here
    /// (`returnUnsentReply`).
    func composerDidDisappear() {
        // The save below skips while this composer is sending.
        if composerState.isSending { savesComposerWhenSendReleases = true }
        scheduleReplyDraftSave()
        composerDirectory.withdraw(generation: composerPresentationGeneration, for: conversationObjectID)
    }

    func saveReplyDraft(onEnqueued: (@Sendable () async -> Void)? = nil) async {
        do {
            try await conversationMutationSerializer.performThrowingCleanupSensitiveMutation(
                onEnqueued: onEnqueued
            ) { [self] in
                try await saveReplyDraftWithoutCleanupInterleaving()
            }
        } catch is CancellationError {
            // A newer request will persist the latest composer state.
        } catch {
            Log.error("Failed to save reply draft", category: .message, error: error)
            sendErrorAlert = ChatSendErrorAlert(title: "Couldn’t Save Draft", message: error.localizedDescription)
        }
    }

    private func saveReplyDraftWithoutCleanupInterleaving() throws {
        // Read live state only after acquiring cleanup's gate: a queued save
        // must not resurrect content that was sent or explicitly discarded.
        // `sendReply` clears the composer at tap, so a save scheduled by a
        // keystroke just before the tap reads the cleared composer here.
        guard !composerState.isSending, !draftRestoreFailed,
              authSession.userEmail == draftAccountEmail else { return }
        // A composer opened for this chat since (see
        // `ChatReplyComposerDirectory`) loaded the stored draft and owns it
        // now; this one's content is stale.
        guard composerDirectory.ownsDraft(
            generation: composerPresentationGeneration,
            for: conversationObjectID
        ) else { return }
        guard conversation.managedObjectContext === viewContext, !conversation.isDeleted else {
            if composerState.hasDraftContent { throw ReplyDraftPersistenceError.conversationUnavailable }
            return
        }
        if !conversation.isInserted {
            // Cleanup may have deleted the row in another context before its
            // merge notification reaches this still-registered UI object.
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "SELF == %@", conversation.objectID)
            request.includesPendingChanges = false
            guard try viewContext.count(for: request) > 0 else {
                if composerState.hasDraftContent { throw ReplyDraftPersistenceError.conversationUnavailable }
                return
            }
        }
        if let target = composerState.replyAnchor, target.objectID.isTemporaryID {
            try viewContext.obtainPermanentIDs(for: [target])
        }
        // Importers own unfinished placeholders and may remove them after
        // this screen disappears. Persist only finalized files so that a
        // later cancellation cannot leave a durable, unsendable attachment.
        let finalizedAttachments = composerState.attachments.filter { attachment in
            guard let localURL = attachment.localURL else { return false }
            return !localURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        try draftStore.save(
            StoredChatReplyDraft(text: replyText, targetURI: composerState.unavailableReplyTargetURI ?? composerState.replyAnchor?.objectID.uriRepresentation(),
                                 recoveredEnvelope: composerState.recoveredReplyEnvelope,
                                 includesQuotedMessage: replyingTo != nil),
            attachments: finalizedAttachments,
            conversationID: conversation.id
        )
    }

    private enum ReplyDraftPersistenceError: LocalizedError {
        case conversationUnavailable

        var errorDescription: String? {
            "This conversation is no longer available. Your draft and attachments are still here."
        }
    }

    private func restoreReplyDraft() {
        // A reply sent from an earlier screen of this chat has not become
        // durable yet, so the stored draft is that reply (saved before its
        // tap). Loaded here, it reappeared ready to be sent again, and a
        // failure that handed the reply over doubled it. The send's
        // transaction removes the stored copy; a failure hands it to this
        // composer, or merges it back into the store.
        guard !composerDirectory.hasUnpersistedSend(for: conversationObjectID) else { return }
        do {
            guard let (snapshot, attachments) = try draftStore.load(conversationID: conversation.id) else { return }
            replyText = snapshot.text
            composerState.attachments = attachments
            composerState.recoveredReplyEnvelope = snapshot.recoveredEnvelope
            if let uri = snapshot.targetURI,
               let objectID = viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri) {
                // A target that still exists but moved to another chat (List-Id
                // repair, a merge) looked restored, yet every send failed with
                // "reopen", and reopening restored it again. Route it to the
                // unavailable state, which shows "Clear target" and blocks send.
                composerState.replaceReplyTarget(
                    resolveMessage(with: objectID).flatMap { isValidReplyTarget($0) ? $0 : nil }
                )
                if composerState.replyAnchor == nil { composerState.unavailableReplyTargetURI = uri }
                if snapshot.includesQuotedMessage == false { replyingTo = nil }
            } else if let uri = snapshot.targetURI {
                composerState.unavailableReplyTargetURI = uri
            }
        } catch {
            draftRestoreFailed = true
            Log.error("Failed to restore reply draft", category: .message, error: error)
            sendErrorAlert = ChatSendErrorAlert(title: "Couldn’t Restore Draft", message: error.localizedDescription)
        }
    }

#if DEBUG
    /// Lets tests join the scheduled draft save (`scheduleReplyDraftSave`,
    /// `composerDidDisappear`) instead of racing it.
    func waitForScheduledReplyDraftSave() async {
        await taskManager.waitForCompletion(of: "saveReplyDraft")
    }
#endif

    func discardReplyDraft() {
        guard !composerState.isSending, !composerState.isProcessingAttachments else { return }
        do {
            try draftStore.discard(conversationID: conversation.id)
        } catch {
            sendErrorAlert = ChatSendErrorAlert(title: "Couldn’t Discard Draft", message: error.localizedDescription)
            return
        }
        draftRestoreFailed = false
        replyText = ""
        composerState.replaceReplyTarget(nil)
        manuallySelectedReplyTargetID = nil
        composerState.recoveredReplyEnvelope = nil
        composerState.unavailableReplyTargetURI = nil
        composerState.discardUnsentAttachments()
        scheduleReplyDraftSave()
    }

    @discardableResult
    func editFailedReply(messageObjectID: NSManagedObjectID) -> Bool {
        guard authSession.userEmail == draftAccountEmail else { return false }
        guard !composerState.isSending, !composerState.isProcessingAttachments else { return false }
        guard !composerState.hasDraftContent, !draftRestoreFailed else {
            sendErrorAlert = ChatSendErrorAlert(title: "Draft Already Open", message: "Send or discard your current draft before editing this failed reply.")
            return false
        }
        guard let message = resolveMessage(with: messageObjectID) else { return false }
        do {
            let (snapshot, attachments) = try draftStore.recover(message, conversation: conversation,
                                                               currentUserEmail: authSession.userEmail ?? "")
            replyText = snapshot.text
            // The saved envelope now owns the destination. Do not retain a
            // previously selected message as a hidden follow-up reply target.
            composerState.replaceReplyTarget(nil)
            manuallySelectedReplyTargetID = nil
            composerState.unavailableReplyTargetURI = nil
            composerState.attachments = attachments
            composerState.recoveredReplyEnvelope = snapshot.recoveredEnvelope
            return true
        } catch {
            sendErrorAlert = ChatSendErrorAlert(title: "Couldn’t Recover Reply", message: error.localizedDescription)
            return false
        }
    }

    func showReplyFailure(messageObjectID: NSManagedObjectID) {
        guard let message = resolveMessage(with: messageObjectID) else { return }
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", message.id)
        request.fetchLimit = 1
        let record = try? viewContext.fetch(request).first
        sendErrorAlert = ChatSendErrorAlert(title: "Reply Not Sent", message: record?.failureReason ?? "This reply was not sent. Choose Edit and resend to try again.")
    }

    func checkReplyDelivery(messageObjectID: NSManagedObjectID) {
        taskManager.run("checkReplyDelivery") { [weak self] in
            guard let self else { return }
            do {
                try await outboundMessageCoordinator.checkDelivery()
                guard let message = resolveMessage(with: messageObjectID),
                      OutboundSendDeliveryState.resolve(for: message) == .deliveryUnknown else { return }
                sendErrorAlert = ChatSendErrorAlert(title: "Delivery Not Confirmed", message: "Check Gmail’s Sent folder before sending again. This reply will not be retried automatically.")
            } catch {
                sendErrorAlert = ChatSendErrorAlert(title: "Couldn’t Check Delivery", message: error.localizedDescription)
            }
        }
    }

    static func isDrainedConversation(
        hidden: Bool,
        archivedAt: Date?,
        lastMessageDate: Date?
    ) -> Bool {
        Conversation.isRetainedDrainedShell(
            hidden: hidden,
            archivedAt: archivedAt,
            lastMessageDate: lastMessageDate
        )
    }

    private var isConversationDrained: Bool {
        conversation.isRetainedDrainedShell
    }

    private func isValidReplyTarget(_ message: Message) -> Bool {
        guard message.managedObjectContext != nil,
              !message.isDeleted,
              message.conversation?.objectID == conversationObjectID,
              OutboundSendDeliveryState.resolve(for: message) == .none,
              // A just-sent row its sync echo has not replaced yet: sync
              // deletes it when the echo lands, so a draft anchored to it
              // would be refused as `replyTargetUnavailable`. Gmail accepting
              // the send makes it resolve `.none`, and since the chat
              // predicate stopped hiding label-less rows it can be the latest
              // visible message and the automatic target.
              OutboundSendDeliveryState.localOptimisticMessageID(for: message) == nil else {
            return false
        }

        if conversation.conversationType == .list {
            guard let conversationListId = conversation.listId,
                  !conversationListId.isEmpty,
                  message.listId == conversationListId else {
                return false
            }
        }

        return true
    }

    // MARK: - Prefetch Operations

    /// Prefetches contacts for the senders of recently visible messages.
    /// Bubble text needs no prefetch: stored `chatPreviewText` covers current
    /// rows, and the legacy derivation memoizes in RenderedMessageCache on load.
    func prefetchSenderContacts(senderEmails: [String]) {
        // Batch prefetch contacts to avoid thundering herd on first load
        let uniqueEmails = Array(Set(senderEmails))
        if !uniqueEmails.isEmpty {
            let contactsResolver = self.contactsResolver
            prefetchTaskManager.runDetached("prefetchContacts") {
                await contactsResolver.prewarm(emails: uniqueEmails)
            }
        }
    }

    /// Warms the access token when the reply field gains focus, so a refresh
    /// of a token near expiry (any reply after about an hour in the
    /// background) happens while the user types instead of between the send
    /// tap and Gmail admission.
    ///
    /// Goes through `getCurrentToken()`, the existing epoch-safe,
    /// single-flighted path; this adds no token producer. Fire-and-forget:
    /// errors are left for the send path to report, and an in-flight warm-up
    /// is never cancelled or duplicated.
    func prewarmReplySendCredentials() {
        guard tokenPrewarmTask == nil,
              authSession.userEmail == draftAccountEmail else { return }
        let tokenManager = self.tokenManager
        tokenPrewarmTask = Task { [weak self] in
            _ = try? await tokenManager.getCurrentToken()
            self?.tokenPrewarmTask = nil
        }
    }

    /// Cancels all prefetch tasks. Call from ChatView.onDisappear.
    func cancelPrefetch() {
        prefetchTaskManager.cancelAll()
    }

    // MARK: - Display Name Resolution

    /// Loads the resolved display name for the conversation participants.
    /// Call from ChatView on appear.
    func loadResolvedDisplayName() {
        // List rows and navigation deliberately use the persisted list title.
        // Resolving participants here cannot affect either surface and would
        // repeat header/contact/photo work for every opened newsletter chat.
        guard Self.shouldLoadResolvedDisplayName(
            conversationType: conversation.conversationType
        ) else {
            return
        }

        prefetchTaskManager.run("displayName") { [weak self] in
            guard let self = self,
                  let myEmail = self.authSession.userEmail else { return }
            let info: ParticipantLoader.ParticipantInfo
            if let conversationContext = self.conversationContext {
                info = await self.participantLoader.loadParticipants(
                    from: self.conversationObjectID,
                    in: conversationContext,
                    currentUserEmail: myEmail,
                    maxParticipants: 4,
                    participantHash: self.conversation.participantHash,
                    fallbackDisplayName: self.conversationDisplayNameHint
                )
            } else {
                info = await self.participantLoader.loadParticipants(
                    from: self.conversation,
                    currentUserEmail: myEmail,
                    maxParticipants: 4
                )
            }

            self.resolvedDisplayName = Self.resolvedDisplayName(
                conversationType: self.conversation.conversationType,
                storedDisplayName: self.conversationDisplayNameHint,
                participantDisplayName: info.formattedDisplayName
            )
            self.effectiveParticipantCount = info.totalUniqueParticipants
        }
    }

    static func shouldLoadResolvedDisplayName(conversationType: ConversationType) -> Bool {
        conversationType != .list
    }

    static func resolvedDisplayName(
        conversationType: ConversationType,
        storedDisplayName: String?,
        participantDisplayName: String
    ) -> String {
        if conversationType == .list,
           let storedDisplayName = storedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedDisplayName.isEmpty {
            return storedDisplayName
        }

        return participantDisplayName
    }

    private func makeForwardModeInput(_ message: Message) throws -> ComposeForwardModeContextBuilder.Input {
        let attachments = try makeForwardAttachmentPayload(message)

        return ComposeForwardModeContextBuilder.Input(
            source: makeForwardSource(message),
            forwardedInlineAttachmentInfos: attachments.inlineAttachmentInfos,
            forwardedRegularAttachments: attachments.regularAttachments
        )
    }

    private func makeForwardSource(_ message: Message) -> MessageFormatBuilder.ForwardSource {
        MessageFormatBuilder.ForwardSource(
            id: message.id,
            subject: message.subject,
            internalDate: message.internalDate,
            isFromMe: message.isFromMe,
            bodyText: message.bodyTextValue,
            snippet: message.snippet,
            originalHTML: loadOriginalHTML(for: message),
            participants: Array(message.conversation?.participants ?? []).compactMap { participant in
                guard let person = participant.person else { return nil }
                return .init(
                    email: person.email,
                    displayName: person.displayName
                )
            }
        )
    }

    private func loadOriginalHTML(for message: Message) -> String? {
        if let html = htmlContentHandler.loadHTML(for: message.id) {
            return html
        }

        guard let bodyStorageURI = message.bodyStorageURI else {
            return nil
        }

        if htmlContentHandler.migrateIfNeeded(from: bodyStorageURI),
           let migratedHTML = htmlContentHandler.loadHTML(for: message.id) {
            return migratedHTML
        }

        guard let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return htmlContentHandler.loadHTML(from: resolvedURL)
    }

    private func makeForwardAttachmentPayload(_ message: Message) throws -> ForwardAttachmentPayload {
        let attachments = message.attachmentsForForwarding
        let inlineAttachments = attachments.filter { attachment in
            guard let contentId = attachment.contentId else { return false }
            return !contentId.isEmpty
        }
        let regularAttachments = attachments.filter { attachment in
            guard let contentId = attachment.contentId else { return true }
            return contentId.isEmpty
        }

        return ForwardAttachmentPayload(
            inlineAttachmentInfos: try outboundAttachmentContextBuilder.buildInlineAttachmentInfos(
                from: inlineAttachments
            ),
            regularAttachments: regularAttachments.map(makeForwardAttachmentSnapshot)
        )
    }

    private func makeForwardAttachmentSnapshot(_ attachment: Attachment) -> ForwardAttachmentSnapshot {
        ForwardAttachmentSnapshot(
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            byteSize: attachment.byteSize,
            localURL: attachment.readableLocalURLValue,
            previewURL: attachment.readablePreviewURLValue,
            width: attachment.width,
            height: attachment.height,
            pageCount: attachment.pageCount
        )
    }

    private struct ForwardAttachmentPayload {
        let inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let regularAttachments: [ForwardAttachmentSnapshot]
    }

    private func resolveMessage(with objectID: NSManagedObjectID) -> Message? {
        if let registered = viewContext.registeredObject(for: objectID) as? Message,
           !registered.isDeleted {
            return registered
        }

        guard let resolved = try? viewContext.existingObject(with: objectID) as? Message,
              !resolved.isDeleted else {
            return nil
        }

        return resolved
    }
}

struct ChatSendErrorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(
        title: String = "Couldn’t Send Reply",
        message: String
    ) {
        self.title = title
        self.message = message
    }
}
