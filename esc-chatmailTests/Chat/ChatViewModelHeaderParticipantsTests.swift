import CoreData
import XCTest
@testable import esc_chatmail

/// The participant info `ChatViewModel` keeps for the Mac chat header's avatar: what
/// `loadResolvedDisplayName()` publishes, and what `cachedParticipantInfo()` reads from the
/// rollup cache the conversation's row filled.
///
/// The chat and the row must ask `ParticipantLoader` for the same number of participants: the
/// number is part of the rollup cache's key, so with two numbers the chat loads and caches a
/// second copy of what the row already holds and never finds the row's
/// (`ConversationRowView.maxDisplayedParticipants`). Each test here stands in for the row with
/// the row's own number, 4, written out.
///
/// Fixtures live in a `TestCoreDataStack` main-queue context
/// (`makeMainQueueViewContext()`): the view model is `@MainActor` and reads the conversation
/// directly. Contacts are never asked: the loader gets a resolver that knows nobody and its
/// own photo loader.
@MainActor
final class ChatViewModelHeaderParticipantsTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
    }

    override func tearDown() async throws {
        context = nil
        stack = nil
        try await super.tearDown()
    }

    /// Revert-check: deleting `self.participantInfo = info` from
    /// `ChatViewModel.loadResolvedDisplayName()` makes this fail: the view model would keep
    /// only the name and the count, as before, and the header would never have a photo of its
    /// own.
    func testLoadResolvedDisplayName_publishesTheParticipantsItLoadedWithTheirPhotos() async {
        let loader = makeLoader(photoURLs: ["https://example.com/ada.png"])
        let conversation = makeConversation(name: "Ada Lovelace", email: "ada@example.com")
        let viewModel = makeViewModel(conversation: conversation, loader: loader)
        XCTAssertNil(viewModel.participantInfo)

        viewModel.loadResolvedDisplayName()
        await waitUntil { viewModel.participantInfo != nil }

        XCTAssertEqual(viewModel.participantInfo?.avatarDisplayNames, ["Ada Lovelace"])
        XCTAssertEqual(
            viewModel.participantInfo?.avatarPhotos.map { $0?.url },
            ["https://example.com/ada.png"]
        )
        XCTAssertEqual(viewModel.resolvedDisplayName, "Ada Lovelace")
        XCTAssertEqual(viewModel.effectiveParticipantCount, 1)
    }

    /// The chat's load fills the cache entry the row reads, so opening a chat never costs the
    /// list a second load of the same participants.
    ///
    /// Revert-check: changing `ChatViewModel.rollupMaxParticipants` to 5 makes this fail: the
    /// chat's load would be cached under a key the row never asks for.
    func testLoadResolvedDisplayName_fillsTheRollupCacheEntryTheRowReads() async {
        let loader = makeLoader(photoURLs: ["https://example.com/ada.png"])
        let conversation = makeConversation(name: "Ada Lovelace", email: "ada@example.com")
        let viewModel = makeViewModel(conversation: conversation, loader: loader)

        viewModel.loadResolvedDisplayName()
        await waitUntil { viewModel.participantInfo != nil }

        let rowsEntry = loader.cachedParticipantInfo(
            conversationObjectID: conversation.objectID,
            participantHash: conversation.participantHash,
            currentUserEmail: Self.myEmail,
            maxParticipants: 4,
            fallbackDisplayName: conversation.displayName,
            includePhotos: true
        )
        XCTAssertEqual(rowsEntry?.avatarDisplayNames, ["Ada Lovelace"])
    }

    /// Opened from its row, a chat finds the row's participants in the cache before its own
    /// load has run, photos included.
    ///
    /// Revert-check: changing `includePhotos: true` to `includePhotos: false` in
    /// `ChatViewModel.cachedParticipantInfo()` makes this fail: the header would get the names
    /// and show initials until the load lands.
    func testCachedParticipantInfo_rowHasLoaded_isTheRowsEntryWithItsPhotos() async {
        let loader = makeLoader(photoURLs: ["https://example.com/ada.png"])
        let conversation = makeConversation(name: "Ada Lovelace", email: "ada@example.com")
        let viewModel = makeViewModel(conversation: conversation, loader: loader)
        XCTAssertNil(viewModel.cachedParticipantInfo(), "Nothing has loaded yet")

        await loadAsTheRowDoes(conversation, loader: loader)

        let cached = viewModel.cachedParticipantInfo()
        XCTAssertEqual(cached?.avatarDisplayNames, ["Ada Lovelace"])
        XCTAssertEqual(cached?.avatarPhotos.map { $0?.url }, ["https://example.com/ada.png"])
        XCTAssertNil(viewModel.participantInfo, "Reading the cache publishes nothing")
    }

    /// Revert-check: changing `maxParticipants: Self.rollupMaxParticipants` to
    /// `maxParticipants: 5` in `ChatViewModel.cachedParticipantInfo()` makes this fail: the chat
    /// would look under a key the row never fills.
    func testCachedParticipantInfo_asksForTheRowsNumberOfParticipants() async {
        let loader = makeLoader(photoURLs: [])
        let conversation = makeConversation(name: "Ada Lovelace", email: "ada@example.com")
        let viewModel = makeViewModel(conversation: conversation, loader: loader)

        await loadAsTheRowDoes(conversation, loader: loader)

        XCTAssertNotNil(viewModel.cachedParticipantInfo())
    }

    /// A mailing list's row loads no participants and shows none, so the header reads none
    /// either, even if something else cached them.
    ///
    /// Revert-check: deleting the `shouldLoadResolvedDisplayName` guard from
    /// `ChatViewModel.cachedParticipantInfo()` makes this fail.
    func testCachedParticipantInfo_mailingList_isNil() async {
        let loader = makeLoader(photoURLs: [])
        let sender = PersonBuilder()
            .withEmail("first-sender@example.com")
            .withDisplayName("First Sender")
            .build(in: context)
        let conversation = ConversationBuilder()
            .asList()
            .withListId("swift-evolution.swift.org")
            .withDisplayName("Swift Evolution")
            .withParticipantHash("l|\(UUID().uuidString)")
            .withParticipant(sender)
            .visible()
            .build(in: context)
        let viewModel = makeViewModel(conversation: conversation, loader: loader)

        await loadAsTheRowDoes(conversation, loader: loader)
        XCTAssertNotNil(
            loader.cachedParticipantInfo(
                conversationObjectID: conversation.objectID,
                participantHash: conversation.participantHash,
                currentUserEmail: Self.myEmail,
                maxParticipants: 4,
                fallbackDisplayName: conversation.displayName,
                includePhotos: true
            ),
            "The fixture did not put the list's participants in the cache"
        )

        XCTAssertNil(viewModel.cachedParticipantInfo())
    }

    // MARK: - Fixtures

    private static let myEmail = "me@example.com"

    private func makeLoader(photoURLs: [String]) -> ParticipantLoader {
        let myEmail = Self.myEmail
        return ParticipantLoader(
            contactsResolver: NobodyContactsResolver(),
            currentUserAliasesProvider: { _, _ in [myEmail] },
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in
                photoURLs.map { ProfilePhoto(source: .cached, imageData: nil, url: $0) }
            },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )
    }

    private func makeConversation(name: String, email: String) -> Conversation {
        let person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(name)
            .build(in: context)
        return ConversationBuilder()
            .withDisplayName(name)
            // Unique per test: the hash is part of the rollup cache's key.
            .withParticipantHash("p|\(UUID().uuidString)")
            .withParticipant(person)
            .visible()
            .recentlyActive()
            .build(in: context)
    }

    private func makeViewModel(conversation: Conversation, loader: ParticipantLoader) -> ChatViewModel {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelHeaderParticipantsTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = Self.myEmail
        let tokenManager = MockTokenManager()
        let base = Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            participantLoader: loader
        ).makeChatDependencies()
        let stack: TestCoreDataStack = self.stack
        return ChatViewModel(
            conversation: conversation,
            chatDependencies: ChatDependencies(
                session: base.session,
                content: base.content,
                messaging: base.messaging,
                contacts: base.contacts,
                storage: ChatStorageDependencies(
                    viewContext: context,
                    makeBackgroundContext: { stack.newBackgroundContext() }
                ),
                fullEmailOpener: base.fullEmailOpener
            )
        )
    }

    /// The row's load (`ConversationRowView.loadContactInfo`), with the row's number of
    /// participants written out.
    private func loadAsTheRowDoes(_ conversation: Conversation, loader: ParticipantLoader) async {
        _ = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: Self.myEmail,
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName
        )
    }

    /// Polls `condition` until it holds or `timeout` elapses. The condition is checked before
    /// the deadline on every pass, so a main-thread stall longer than the timeout cannot fail a
    /// condition that came true during the stall.
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while await !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
