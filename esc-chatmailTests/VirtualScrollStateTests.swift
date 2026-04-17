import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class VirtualScrollStateTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.viewContext
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    func testLoadMessagePage_returnsOrderedObjectIDsFromBackgroundContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 6)
        let page = await VirtualScrollState.loadMessagePage(
            conversationId: conversation.id.uuidString,
            range: 1..<4,
            in: stack.newBackgroundContext()
        )

        XCTAssertEqual(page.totalCount, 6)
        XCTAssertEqual(page.messageIDs, Array(messages[1..<4]).map(\.objectID))
    }

    func testInitialLoad_publishesOnlyViewContextMessages() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs && !state.isLoadingMore
        }

        XCTAssertEqual(state.totalMessageCount, 8)
        XCTAssertTrue(state.visibleMessages.allSatisfy { $0.managedObjectContext === self.viewContext })
    }

    func testInitialLoadFromEnd_publishesNewestMessagesOnViewContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 8)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 3,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            initialWindowPosition: .end,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() }
        )
        defer { state.cleanup() }

        let expectedIDs = Array(messages.suffix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedIDs && !state.isLoadingMore
        }

        XCTAssertEqual(state.visibleRangeStartIndex, 4)
        XCTAssertEqual(state.absoluteIndex(forVisibleIndex: 0), 4)
        XCTAssertEqual(state.absoluteIndex(forVisibleIndex: 3), 7)
        XCTAssertTrue(state.visibleMessages.allSatisfy { $0.managedObjectContext === self.viewContext })
    }

    func testRapidOverlappingWindowLoads_keepPublishedMessagesOnViewContext() async throws {
        let (conversation, messages) = try makeConversationWithMessages(count: 24)
        let configuration = VirtualScrollConfiguration(
            visibleItemCount: 4,
            bufferSize: 1,
            pageSize: 4,
            preloadThreshold: 1
        )
        let stack = self.stack!

        let delayedLoader: VirtualScrollState.MessagePageLoader = { conversationId, range, context in
            if range.lowerBound > 0 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled {
                    return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
                }
            }

            return await VirtualScrollState.loadMessagePage(
                conversationId: conversationId,
                range: range,
                in: context
            )
        }

        let state = VirtualScrollState(
            conversationId: conversation.id.uuidString,
            configuration: configuration,
            viewContext: viewContext,
            makeBackgroundContext: { stack.newBackgroundContext() },
            pageLoader: delayedLoader
        )
        defer { state.cleanup() }

        let initialIDs = Array(messages.prefix(4)).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == initialIDs && !state.isLoadingMore
        }

        state.markIndexVisible(8)
        state.markIndexVisible(14)

        let expectedFinalWindowIDs = Array(messages[13..<19]).map(\.objectID)
        await waitUntil {
            state.visibleMessages.map(\.objectID) == expectedFinalWindowIDs && !state.isLoadingMore
        }

        XCTAssertTrue(state.visibleMessages.allSatisfy { $0.managedObjectContext === self.viewContext })
    }

    private func makeConversationWithMessages(count: Int) throws -> (Conversation, [Message]) {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)

        var messages: [Message] = []
        for index in 0..<count {
            let message = MessageBuilder()
                .withId("virtual-scroll-\(index)")
                .withSubject("Message \(index)")
                .withDate(Date(timeIntervalSince1970: TimeInterval(index)))
                .inConversation(conversation)
                .build(in: viewContext)
            messages.append(message)
        }

        try viewContext.save()
        return (conversation, messages)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
