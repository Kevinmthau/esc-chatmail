import XCTest
import CoreData
@testable import esc_chatmail

/// The composer names a reply's recipients where they are not the chat's own
/// people (`ChatViewModel.refreshAnnouncedReplyRecipients`).
///
/// The chat here is the one a merge leaves once a contact card stops linking
/// two addresses: its one row is Alex, and it still holds Sam's mail. A reply
/// to Sam's message goes to Sam, and the chat's title still says Alex.
///
/// Main-queue context, as in `ChatViewModelTests`: the view model reads its
/// context directly on the main actor.
@MainActor
final class ChatViewModelAnnouncedReplyRecipientsTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var aliasLoader: AliasLoaderStub!
    private var conversation: Conversation!
    private var fromAlex: Message!
    private var fromSam: Message!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        aliasLoader = AliasLoaderStub()

        conversation = ConversationBuilder()
            .withDisplayName("Alex")
            .visible()
            .recentlyActive()
            .build(in: context)
        addConversationRow(email: "alex@example.com")
        fromAlex = makeInboundMessage(
            id: "from-alex", thread: "alex-thread", sender: "alex@example.com", at: 100
        )
        fromSam = makeInboundMessage(
            id: "from-sam", thread: "sam-thread", sender: "sam@example.com", at: 200
        )
        try context.obtainPermanentIDs(for: [conversation, fromAlex, fromSam])
        try context.save()
    }

    override func tearDown() {
        aliasLoader.resumeAll()
        fromSam = nil
        fromAlex = nil
        conversation = nil
        aliasLoader = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: the `composerState.$replyingTo` sink in
    // `ChatViewModel.init`, both ways. Without it nothing is named when Sam's
    // message becomes the target by a pick, and once named, Sam stays named
    // after the target moves to Alex's message: the row would then say the
    // reply goes to someone it does not go to.
    func testAnnouncedReplyRecipients_followTheReplyTarget() async {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.composerState.announcedReplyRecipients)

        viewModel.setReplyingTo(fromSam)
        await waitUntil { viewModel.composerState.announcedReplyRecipients == ["sam@example.com"] }

        // The chat's own person: settled in the turn of the pick, with no
        // alias load to wait for.
        let loadsBefore = aliasLoader.loadCount
        viewModel.setReplyingTo(fromAlex)
        XCTAssertNil(viewModel.composerState.announcedReplyRecipients)
        XCTAssertEqual(aliasLoader.loadCount, loadsBefore)
    }

    /// The X drops the quote and keeps the reply's destination, so the
    /// recipients stay named: they are then the only sign of where it goes.
    func testAnnouncedReplyRecipients_quoteDropped_staysNamed() async {
        let viewModel = makeViewModel()
        viewModel.setReplyingTo(fromSam)
        await waitUntil { viewModel.composerState.announcedReplyRecipients == ["sam@example.com"] }
        let loadsBefore = aliasLoader.loadCount

        // The quote's X button writes directly to the composer's binding.
        viewModel.composerState.replyingTo = nil

        XCTAssertEqual(viewModel.composerState.replyAnchor, fromSam)
        // The destination was asked again and is the same.
        await waitUntil { self.aliasLoader.loadCount > loadsBefore }
        await waitUntil { viewModel.composerState.announcedReplyRecipients == ["sam@example.com"] }
    }

    /// A chat that loads with Sam's message as its newest takes it as the
    /// automatic target, and says who the reply goes to without a pick.
    func testAnnouncedReplyRecipients_automaticTargetAtLoad_isNamed() async {
        let viewModel = makeViewModel()

        viewModel.initializeReplyingTo(lastMessage: fromSam)

        XCTAssertEqual(viewModel.replyingTo, fromSam)
        await waitUntil { viewModel.composerState.announcedReplyRecipients == ["sam@example.com"] }
    }

    // Revert-check: the `refreshAnnouncedReplyRecipients` call that ends
    // `ChatViewModel.initializeReplyingTo`. A restored draft's target is set
    // while the view model is being created, before anything listens for it,
    // and the load's automatic pass leaves a draft's target alone: without
    // the call a reopened chat names nobody.
    func testAnnouncedReplyRecipients_targetRestoredWithADraft_isNamedWhenTheChatLoads() async {
        let composerDirectory = ChatReplyComposerDirectory()
        let first = makeViewModel(composerDirectory: composerDirectory)
        first.setReplyingTo(fromSam)
        first.replyText = "On my way"
        await first.saveReplyDraft()
        first.composerDidDisappear()

        let reopened = makeViewModel(composerDirectory: composerDirectory)
        XCTAssertEqual(reopened.replyingTo, fromSam, "The draft's target must be restored, or this is not the case under test")
        XCTAssertNil(reopened.composerState.announcedReplyRecipients, "Nothing is read for a chat that has not loaded")

        reopened.initializeReplyingTo(lastMessage: fromSam)

        await waitUntil { reopened.composerState.announcedReplyRecipients == ["sam@example.com"] }
    }

    // Revert-check: the `generation == self.announcedReplyRecipientsGeneration`
    // guard in `ChatViewModel.refreshAnnouncedReplyRecipients`. Without it the
    // answer about Sam's message, which waited for the aliases, lands after
    // the target has moved to Alex's and names Sam above a reply to Alex.
    //
    // HONEST SCOPE: a dropped answer leaves nothing to observe, so this
    // watches for a quarter of a second after the aliases are delivered. A
    // stale answer that took longer than that to land would pass.
    func testAnnouncedReplyRecipients_answerOvertakenByALaterTarget_isDropped() async {
        let viewModel = makeViewModel()
        aliasLoader.suspendsLoads = true
        viewModel.setReplyingTo(fromSam)
        await waitUntil { self.aliasLoader.suspendedLoadCount == 1 }

        viewModel.setReplyingTo(fromAlex)
        XCTAssertNil(viewModel.composerState.announcedReplyRecipients)
        aliasLoader.resumeAll()

        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            XCTAssertNil(viewModel.composerState.announcedReplyRecipients)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Helpers

    private func makeViewModel(
        composerDirectory: ChatReplyComposerDirectory? = nil
    ) -> ChatViewModel {
        // Per view model unless a test reopens the chat, so no other test's
        // view model can own this one's draft.
        let composerDirectory = composerDirectory ?? ChatReplyComposerDirectory()
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelAnnouncedReplyRecipientsTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = "me@example.com"
        let tokenManager = MockTokenManager()
        let base = Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        ).makeChatDependencies()
        let coreDataStack: TestCoreDataStack = self.stack
        let aliases: AliasLoaderStub = self.aliasLoader
        // The reply builder on this test's context and with this test's
        // aliases: the shared one reads the app's store and fills the
        // process-wide alias cache.
        let replyContextBuilder = OutboundReplyContextBuilder(
            viewContext: context,
            replyMetadataBuilder: ReplyMetadataBuilder(authSession: authSession),
            replyHTMLContentLoader: HTMLContentLoader(
                contentHandler: HTMLContentHandler(),
                sanitizer: .shared
            ),
            loadUserAliases: { await aliases.load() }
        )
        return ChatViewModel(
            conversation: conversation,
            chatDependencies: ChatDependencies(
                session: base.session,
                content: base.content,
                messaging: ChatMessagingDependencies(
                    messageActions: base.messaging.messageActions,
                    outboundMessageCoordinator: base.messaging.outboundMessageCoordinator,
                    outboundAttachmentContextBuilder: base.messaging.outboundAttachmentContextBuilder,
                    outboundReplyContextBuilder: replyContextBuilder,
                    composeForwardModeContextBuilder: base.messaging.composeForwardModeContextBuilder
                ),
                contacts: base.contacts,
                storage: ChatStorageDependencies(
                    viewContext: context,
                    makeBackgroundContext: { coreDataStack.newBackgroundContext() }
                ),
                fullEmailOpener: base.fullEmailOpener
            ),
            composerDirectory: composerDirectory
        )
    }

    private func addConversationRow(email: String) {
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person(email)
        participant.conversation = conversation
    }

    /// A message as a sync stores it: a sender, a From row and a To row.
    private func makeInboundMessage(id: String, thread: String, sender: String, at seconds: TimeInterval) -> Message {
        let message = MessageBuilder()
            .withId("\(id)-\(UUID().uuidString)")
            .withThreadId(thread)
            .withSubject("Dinner")
            .withDate(Date(timeIntervalSince1970: seconds))
            .withSender(email: sender)
            .inConversation(conversation)
            .build(in: context)
        addMessageRow(email: sender, kind: .from, to: message)
        addMessageRow(email: "me@example.com", kind: .to, to: message)
        return message
    }

    private func addMessageRow(email: String, kind: ParticipantKind, to message: Message) {
        let participant = context.insertTestObject(MessageParticipant.self)
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person(email)
        participant.message = message
    }

    private func person(_ email: String) -> Person {
        PersonBuilder().withEmail(email).noDisplayName().build(in: context)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

/// Stands in for the alias load a reply's addressing waits for: it counts the
/// loads and, when asked to, holds each one until `resumeAll()`.
@MainActor
private final class AliasLoaderStub {
    var suspendsLoads = false
    private(set) var loadCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var suspendedLoadCount: Int { continuations.count }

    func load() async -> Set<String> {
        loadCount += 1
        if suspendsLoads {
            await withCheckedContinuation { continuations.append($0) }
        }
        return []
    }

    func resumeAll() {
        suspendsLoads = false
        let held = continuations
        continuations.removeAll()
        held.forEach { $0.resume() }
    }
}
