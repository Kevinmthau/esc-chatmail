#if os(iOS)
import XCTest
import SwiftUI
import CoreData
import UIKit
@testable import esc_chatmail

/// The chat transcript mounted as the iPhone's chat mounts it, in a `NavigationStack` in a window
/// with the window's safe area, over a seeded store, to see how its hidden initial-anchor pass
/// ends (architecture review 2026-11, chat-transcript-ui#3).
///
/// The reveal rests on how SwiftUI's lazy stack realizes rows under the cover and where
/// `scrollTo` lands. `ChatMessagesCoordinator` infers both from geometry and has bounded ways
/// out of a pass that never sees them (a time limit, a retry budget, a watchdog), each of which
/// reveals the transcript anyway, so a change of that behaviour in an OS release would show
/// only as warnings in the device log. Here it is a test: a pass over plain text rows must end
/// `.confirmed`, which it does only with the bottom anchor on screen and the newest row's view
/// in the hierarchy (`ChatTranscriptRealizationPolicy`), after however many realization nudges
/// (it prints the count). CI runs it on its iOS 26 runtime; it was written on the iOS 27.0
/// simulator, where every run confirmed after one nudge.
///
/// Hygiene, as the review lists it. The view context is main-queue: `VirtualScrollState` and
/// the coordinator touch it on the main actor. The chat's appear marks unread mail read, so
/// every row is read and the chat's `MessageActions` work on this test's store. Contacts are
/// `NobodyContactsResolver`, for the bubbles' sender loads and the participant loader alike;
/// the chat's `HTMLContentHandler` is rooted in a temporary directory; the auth session is the
/// test's own, with an empty keychain and a throwaway defaults suite; the message IDs carry a
/// UUID, because they reach process-wide caches. Waits are by wall-clock deadline. Shared
/// singletons remain: the bubble loader's `HTMLContentLoader.shared` and
/// `HTMLContentRecoveryService.shared`, and `MessageActions`' `PendingActionsManager.shared`.
/// With plain text rows, all read, none of them is asked to do anything.
///
/// HONEST SCOPE: one OS runtime per run, an iPhone-sized window and plain text rows. Not
/// `ChatView` itself: its header, sheets and draft wiring are left out, only its
/// `NavigationStack` and title kept. No HTML card, image or Mac transcript is mounted, and the
/// pre-iOS 18 `.top` anchor branch cannot be run on a runtime that has
/// `defaultScrollAnchor(_:for:)`.
@MainActor
final class ChatTranscriptRevealHostedTests: XCTestCase {
    /// Sixty text rows, the window's last twenty published, revealed at the newest row.
    ///
    /// Revert-check: deleting `scrollState.markRowRealized(row.id)` from the row's `onAppear` in
    /// `ChatMessagesView` leaves the newest row unrealized for the pass, which nudges and then
    /// ends on a fallback (`.attemptsExhausted` or `.timeLimitReached`), not `.confirmed`.
    func testMountedTranscript_ofSixtyTextRows_revealsConfirmedAtItsNewestRow() async throws {
        let fixture = try makeFixture(messageCount: 60)
        var outcomes: [ChatMessagesCoordinator.InitialRevealOutcome] = []

        let host = try mountInNavigationStack(
            RevealHarness(
                conversation: fixture.conversation,
                viewModel: fixture.viewModel,
                chatDependencies: fixture.chatDependencies,
                onInitialReveal: { outcomes.append($0) }
            )
            .environmentObject(fixture.dependencies)
        )
        defer { unmount(host) }

        await waitUntil(timeout: 10) { !outcomes.isEmpty }

        // Confirmed, however many nudges it took: on the iOS 27.0 simulator every run took
        // one, in this mount and in a bare window alike (2026-11-28), so the lazy stack leaves
        // the newest row unrealized at the content end on each open there and the nudge is
        // what realizes it. The count is printed so another runtime's shows in its log.
        XCTAssertEqual(outcomes.count, 1, "\(outcomes)")
        guard case .confirmed(let realizationNudges)? = outcomes.first else {
            return XCTFail("The reveal was not confirmed: \(outcomes)")
        }
        print("ChatTranscriptRevealHostedTests: confirmed after \(realizationNudges) realization nudge(s)")
        let transcript = try XCTUnwrap(transcriptScrollView(in: host.view))
        let visibleBottom = transcript.contentOffset.y + transcript.bounds.height
            - transcript.adjustedContentInset.bottom
        XCTAssertEqual(
            visibleBottom,
            transcript.contentSize.height,
            accuracy: 2,
            "Revealed at the transcript's end: offset \(transcript.contentOffset.y), height \(transcript.bounds.height), content \(transcript.contentSize.height), inset \(transcript.adjustedContentInset)"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let stack: TestCoreDataStack
        let dependencies: Dependencies
        let chatDependencies: ChatDependencies
        let conversation: Conversation
        let viewModel: ChatViewModel
    }

    private func makeFixture(messageCount: Int) throws -> Fixture {
        let stack = TestCoreDataStack()
        let viewContext = stack.makeMainQueueViewContext()
        let conversation = ConversationBuilder()
            .withDisplayName("Reveal")
            .visible()
            .recentlyActive()
            .asPersonal()
            .build(in: viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let idSuffix = UUID().uuidString
        for index in 0..<messageCount {
            var builder = MessageBuilder()
                .withId("reveal-\(idSuffix)-\(String(format: "%03d", index))")
                .withSubject("")
                .withBody(Self.body(at: index))
                .withSnippet(Self.body(at: index))
                .withDate(start.addingTimeInterval(TimeInterval(index * 60)))
                .withSender(email: "friend@example.com", name: "Friend")
                .read()
                .inConversation(conversation)
            if index.isMultiple(of: 3) {
                builder = builder.fromMe()
            }
            _ = builder.build(in: viewContext)
        }
        try viewContext.save()

        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatTranscriptRevealHostedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }
        let htmlContentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        let contactsResolver = NobodyContactsResolver()
        let participantLoader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] }
        )
        let tokenManager = MockTokenManager()
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ChatTranscriptRevealHostedTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = "me@example.com"
        let dependencies = Dependencies(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            keychainService: MockKeychainService(),
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            contactsResolver: contactsResolver,
            htmlContentHandler: htmlContentHandler,
            participantLoader: participantLoader
        )
        let made = dependencies.makeChatDependencies()
        // The chat's own view context is this suite's main-queue one, which holds the
        // fixtures, as the app's chat holds the app's main-queue view context.
        let chatDependencies = ChatDependencies(
            session: made.session,
            content: made.content,
            messaging: made.messaging,
            contacts: made.contacts,
            storage: ChatStorageDependencies(
                viewContext: viewContext,
                makeBackgroundContext: { stack.newBackgroundContext() }
            ),
            fullEmailOpener: made.fullEmailOpener
        )
        let viewModel = ChatViewModel(conversation: conversation, chatDependencies: chatDependencies)
        return Fixture(
            stack: stack,
            dependencies: dependencies,
            chatDependencies: chatDependencies,
            conversation: conversation,
            viewModel: viewModel
        )
    }

    /// One to four lines of text, so rows have different heights, as a chat's do.
    private static func body(at index: Int) -> String {
        let sentence = "Message \(index) in the transcript the reveal is measured over."
        return Array(repeating: sentence, count: 1 + index % 4).joined(separator: " ")
    }

    // MARK: - Helpers

    /// The transcript's scroll view: the one with the tallest content in the hosted hierarchy
    /// (the reply bar's field scrolls too, with far less).
    private func transcriptScrollView(in view: UIView) -> UIScrollView? {
        var scrollViews: [UIScrollView] = []
        var queue = [view]
        while let next = queue.popLast() {
            if let scrollView = next as? UIScrollView {
                scrollViews.append(scrollView)
            }
            queue.append(contentsOf: next.subviews)
        }
        return scrollViews.max { $0.contentSize.height < $1.contentSize.height }
    }

    /// Mounts `rootView` in a `NavigationStack`, as the iPhone pushes a chat, in a window from
    /// `makeTestHostWindow()` that keeps the window's safe area (`mountInTestWindow` strips
    /// it), laid out once, and hides the window at teardown.
    private func mountInNavigationStack<Content: View>(_ rootView: Content) throws -> UIViewController {
        let host = UIHostingController(rootView: NavigationStack {
            rootView
                .navigationTitle("Reveal")
                .navigationBarTitleDisplayMode(.inline)
        })
        let window = try makeTestHostWindow()
        window.rootViewController = host
        window.isHidden = false
        addTeardownBlock { @MainActor in
            window.isHidden = true
        }
        host.view.layoutIfNeeded()
        return host
    }

    /// Takes the chat out of its window, so its `onDisappear` stops the scroll state and the
    /// coordinator before the store goes.
    private func unmount(_ host: UIViewController) {
        host.view.window?.rootViewController = nil
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
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

/// `ChatMessagesView` as `ChatView` mounts it on the iPhone, with a reply field focus of its
/// own and nothing else of the chat screen.
private struct RevealHarness: View {
    let conversation: Conversation
    let viewModel: ChatViewModel
    let chatDependencies: ChatDependencies
    let onInitialReveal: (ChatMessagesCoordinator.InitialRevealOutcome) -> Void

    @FocusState private var isFieldFocused: Bool
    @StateObject private var focusBridge = ReplyFieldFocusBridge()

    var body: some View {
        ChatMessagesView(
            conversation: conversation,
            viewModel: viewModel,
            chatDependencies: chatDependencies,
            isEffectivelyOneToOneConversation: true,
            isChatActiveAndUncovered: true,
            bubbleStyle: .standard,
            composerStyle: .bar,
            isTextFieldFocused: ChatComposerFocus(fieldBinding: $isFieldFocused, bridge: focusBridge),
            onOpenFullMessage: { _, _ in },
            onInitialReveal: onInitialReveal
        )
    }
}
#endif
