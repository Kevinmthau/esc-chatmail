#if os(iOS)
import XCTest
import SwiftUI
import CoreData
@testable import esc_chatmail

/// A mounted bubble reloads when its message's HTML source changes on disk with no stored
/// field changed (architecture review 2026-11, chat-transcript-ui#4). The body no longer reads
/// the file's signature, and with `.equatable()` nothing else re-runs it for such a change, so
/// the reload comes from `HTMLContentLoader.contentSourceDidChangeNotification` through the
/// view model's `sourceRevision` and the bubble's load task identity.
///
/// The bubble is mounted alone, with `Dependencies` in the environment for its inline
/// attachment trigger, over this suite's main-queue context; its loader is a mock that counts
/// loads, so no file or Contacts store is read.
@MainActor
final class MessageBubbleSourceRevisionHostedTests: XCTestCase {
    /// Revert-check: `sourceRevision: 0` in place of `viewModel.sourceRevision` in
    /// `MessageBubble.loadSignature` leaves the load count at 1.
    func testMountedBubble_sourceChangeForItsMessage_reloadsIt() async throws {
        let stack = TestCoreDataStack()
        let viewContext = stack.makeMainQueueViewContext()
        let messageID = "source-revision-hosted-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageID)
            .withBody("Hello")
            .read()
            .build(in: viewContext)
        try viewContext.save()
        let row = ChatMessageRowModelMapper.map(message)
        let loader = MockMessageBubbleLoader(senderResults: [], contentResults: [])
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageBubbleSourceRevisionHostedTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }
        let htmlContentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        let tokenManager = MockTokenManager()
        let dependencies = Dependencies(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            keychainService: MockKeychainService(),
            authSession: AuthSession(
                tokenManagerProvider: { MockTokenManager() },
                keychainService: MockKeychainService(),
                userDefaults: UserDefaults(suiteName: "MessageBubbleSourceRevisionHostedTests.\(UUID().uuidString)")!,
                clearConversationCaches: {},
                cleanupDownloads: {},
                resetCoreDataStore: {},
                clearAttachmentCache: {}
            ),
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            contactsResolver: NobodyContactsResolver(),
            htmlContentHandler: htmlContentHandler
        )

        let host = try mountInTestWindow(
            MessageBubble(
                message: row,
                messageBubbleLoader: loader,
                htmlContentHandler: htmlContentHandler,
                fullEmailOpener: FullEmailWebViewManager.shared,
                originalEmailSourceWarmer: OriginalEmailSourceLoader.shared,
                isEffectivelyOneToOneConversation: true,
                transcriptWidth: 390,
                onOpenFullMessage: { _, _ in },
                onSendRecoveryAction: { _ in }
            )
            .environmentObject(dependencies)
        )
        defer { host.view.window?.rootViewController = nil }

        await waitUntilLoadCount(1, of: loader)
        HTMLContentLoader.postContentSourceDidChange(messageId: messageID, sourceSignature: "sha256:recovered")

        await waitUntilLoadCount(2, of: loader)
    }

    private func waitUntilLoadCount(
        _ expected: Int,
        of loader: MockMessageBubbleLoader,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await loader.contentCallCount() < expected {
            guard Date() < deadline else {
                let count = await loader.contentCallCount()
                XCTFail("Timed out waiting for \(expected) loads; saw \(count)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
