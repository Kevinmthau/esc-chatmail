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
    private let conversationMutationSerializer: ConversationRollupMutationSerializer
    @Published private(set) var draftRestoreFailed = false

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
        conversationMutationSerializer: ConversationRollupMutationSerializer = .shared
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
        self.conversationMutationSerializer = conversationMutationSerializer
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
        guard !composerState.isSending,
              !composerState.hasDraftContent,
              composerState.replyAnchor == nil,
              composerState.recoveredReplyEnvelope == nil,
              composerState.unavailableReplyTargetURI == nil,
              let lastMessage,
              isValidReplyTarget(lastMessage) else { return }
        replyingTo = lastMessage
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
    func updateReplyingToIfNewSubject(lastMessage: Message?) {
        guard !composerState.isSending else { return }

        // If user cleared replyingTo (tapped X), don't auto-update
        guard let currentReplyingTo = replyingTo else { return }

        // A selected message or an active draft owns its destination. If sync
        // invalidates that target, send validation keeps the draft for recovery.
        guard !composerState.hasDraftContent,
              manuallySelectedReplyTargetID != currentReplyingTo.objectID else { return }

        guard isValidReplyTarget(currentReplyingTo) else {
            composerState.replaceReplyTarget(lastMessage.flatMap { isValidReplyTarget($0) ? $0 : nil })
            return
        }

        guard let lastMessage, isValidReplyTarget(lastMessage) else { return }

        // List conversations can combine multiple Gmail threads that happen to
        // share a subject. Follow the newest thread so reply metadata and quoted
        // content do not stay anchored to an older list post.
        let currentSubject = currentReplyingTo.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newSubject = lastMessage.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let listThreadChanged =
            conversation.conversationType == .list &&
            !lastMessage.gmThreadId.isEmpty &&
            currentReplyingTo.gmThreadId != lastMessage.gmThreadId

        if currentSubject != newSubject || listThreadChanged {
            replyingTo = lastMessage
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

    /// Reports the durable optimistic identity as soon as it exists, but keeps
    /// the draft owned and locked until local preflight reaches transmission
    /// admission. The returned result represents that later admission point.
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
        defer {
            composerState.finishSending()
            scheduleReplyDraftSave()
        }

        guard !isConversationDrained else {
            Log.warning(
                "Blocked reply send because the anchored conversation drained during rerouting",
                category: .message
            )
            sendErrorAlert = ChatSendErrorAlert(
                message: "This conversation moved while you were replying. Your draft and attachments are still here."
            )
            return nil
        }

        let result: OutboundMessageResult?
        do {
            if let target = composerState.replyAnchor, target.objectID.isTemporaryID {
                try viewContext.obtainPermanentIDs(for: [target])
            }
            let attachmentContexts = try outboundAttachmentContextBuilder.buildSendAttachments(
                from: attachments
            )
            result = try await outboundMessageCoordinator.send(
                .reply(
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
                        )
                    )
                ),
                onOptimisticMessagePersisted: onOptimisticMessagePersisted
            )
        } catch {
            Log.error("Failed to prepare reply send", category: .message, error: error)
            sendErrorAlert = ChatSendErrorAlert(message: error.localizedDescription)
            return nil
        }
        guard let result else { return nil }

        // Clear only after local preflight reaches durable transmission admission.
        // Keep the reply target so another message in this chat retains its
        // subject and threading headers while the sent-message echo arrives.
        // A recovered envelope serves the same purpose when its original
        // target is no longer available locally.
        replyText = ""
        composerState.attachments = []
        return result
    }

    // MARK: - Durable reply drafts and failed-send recovery

    /// Retain the screen state until its lifecycle-triggered save finishes, even
    /// after navigation releases the view. Repeated requests replace older work.
    func scheduleReplyDraftSave() {
        taskManager.run("saveReplyDraft") { [self] in
            await saveReplyDraft()
        }
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
        guard !composerState.isSending, !draftRestoreFailed,
              authSession.userEmail == draftAccountEmail else { return }
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
        do {
            guard let (snapshot, attachments) = try draftStore.load(conversationID: conversation.id) else { return }
            replyText = snapshot.text
            composerState.attachments = attachments
            composerState.recoveredReplyEnvelope = snapshot.recoveredEnvelope
            if let uri = snapshot.targetURI,
               let objectID = viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri) {
                composerState.replaceReplyTarget(resolveMessage(with: objectID))
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
              OutboundSendDeliveryState.resolve(for: message) == .none else {
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
