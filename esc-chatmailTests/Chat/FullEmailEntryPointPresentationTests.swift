import CoreGraphics
import XCTest
@testable import esc_chatmail

@MainActor
final class FullEmailEntryPointPresentationTests: XCTestCase {
    func testInboxListViewStoresOpenSessionInsteadOfMessageDrivenSheetState() {
        let deps = makeDependencies()
        let view = InboxListView(
            deps: deps,
            fullEmailReaderCoordinator: FullEmailReaderCoordinator(
                fullEmailOpener: MockEntryPointFullEmailOpener(preparedPayload: nil)
            )
        )

        let labels = storedPropertyLabels(of: view)

        XCTAssertTrue(labels.contains("_fullEmailOpenSession"))
        XCTAssertFalse(labels.contains("_selectedMessage"))
        XCTAssertFalse(labels.contains("_showingWebView"))
    }

    func testVirtualScrollChatViewStoresOpenSessionInsteadOfMessageDrivenSheetState() {
        let deps = makeDependencies()
        let conversation = ConversationBuilder()
            .withDisplayName("Virtual Scroll")
            .visible()
            .recentlyActive()
            .build(in: deps.viewContext)
        let view = VirtualScrollChatView(
            conversation: conversation,
            chatDependencies: deps.makeChatDependencies(
                fullEmailOpener: MockEntryPointFullEmailOpener(preparedPayload: nil)
            )
        )

        let labels = storedPropertyLabels(of: view)

        XCTAssertTrue(labels.contains("_fullEmailOpenSession"))
        XCTAssertFalse(labels.contains("_messageToViewInFull"))
    }

    private func storedPropertyLabels<T>(of value: T) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    private func makeDependencies() -> Dependencies {
        let tokenManager = MockTokenManager()
        let authSession = AuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "FullEmailEntryPointPresentationTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        return Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
    }
}

@MainActor
private final class MockEntryPointFullEmailOpener: FullEmailOpening {
    let preparedPayload: FullEmailOpenPayload?

    init(preparedPayload: FullEmailOpenPayload?) {
        self.preparedPayload = preparedPayload
    }

    func preparedOpenPayload(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat
    ) -> FullEmailOpenPayload? {
        preparedPayload
    }

    func prewarmOnOpen(message: Message) {}
}
