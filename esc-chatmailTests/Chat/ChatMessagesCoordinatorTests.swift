import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ChatMessagesCoordinatorTests: XCTestCase {
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

    func testHandleAppear_runsInitialBottomAnchorSequenceAndRefreshesGrouping() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "Alice@Example.com",
            "alice@example.com",
            "bob@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var markConversationAsReadCount = 0
        var initializedReplyTargets: [String?] = []
        var loadResolvedDisplayNameCount = 0
        var prefetchedMessageBatches: [[String]] = []
        var prefetchedSenderEmailBatches: [[String]] = []
        var groupingRequests: [[String]] = []
        var sleepCalls: [UInt64] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {
                loadLatestWindowCount += 1
            },
            markConversationAsReadIfNeeded: {
                markConversationAsReadCount += 1
            },
            initializeReplyingTo: { lastMessage in
                initializedReplyTargets.append(lastMessage?.id)
            },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {
                loadResolvedDisplayNameCount += 1
            },
            prefetchRecentContent: { messageIds, senderEmails in
                prefetchedMessageBatches.append(messageIds)
                prefetchedSenderEmailBatches.append(senderEmails)
            },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { senderEmails in
                groupingRequests.append(senderEmails)
                return Dictionary(
                    uniqueKeysWithValues: senderEmails.map { email in
                        let normalizedEmail = EmailNormalizer.normalize(email)
                        return (normalizedEmail, "group:\(normalizedEmail)")
                    }
                )
            },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { nanoseconds in
                sleepCalls.append(nanoseconds)
            }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            coordinator.isReadyToShow &&
                anchorSteps.count == 5 &&
                groupingRequests.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 1)
        XCTAssertEqual(markConversationAsReadCount, 1)
        XCTAssertEqual(initializedReplyTargets, [messages.last?.id])
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertEqual(prefetchedMessageBatches, [messages.map(\.id)])
        XCTAssertEqual(
            prefetchedSenderEmailBatches,
            [[
                "Alice@Example.com",
                "alice@example.com",
                "bob@example.com"
            ]]
        )
        XCTAssertEqual(groupingRequests, [["Alice@Example.com", "bob@example.com"]])
        XCTAssertEqual(
            sleepCalls,
            [
                UInt64(UIConfig.contentChangeScrollDelay * 1_000_000_000),
                UInt64(UIConfig.initialScrollDelay * 1_000_000_000),
                250_000_000,
                750_000_000,
                1_500_000_000
            ]
        )
        XCTAssertEqual(
            anchorSteps.map(\.logMessage),
            [
                "ChatView initial scroll -> bottom anchor",
                "ChatView follow-up scroll -> bottom anchor",
                "ChatView stabilization scroll (0.25s) -> bottom anchor",
                "ChatView stabilization scroll (0.75s) -> bottom anchor",
                "ChatView stabilization scroll (1.5s) -> bottom anchor"
            ]
        )
        XCTAssertEqual(
            coordinator.senderGroupingKeysByEmail,
            [
                "alice@example.com": "group:alice@example.com",
                "bob@example.com": "group:bob@example.com"
            ]
        )
        XCTAssertEqual(
            coordinator.senderRunKey(
                for: rows[0],
                isEffectivelyOneToOneConversation: true
            ),
            "group:alice@example.com"
        )
        XCTAssertEqual(
            coordinator.senderRunKey(
                for: rows[0],
                isEffectivelyOneToOneConversation: false
            ),
            "email:alice@example.com"
        )
    }

    func testHandleDisplayedMessagesChange_prefetchesTrailingVisibleWindow() async throws {
        let senderEmails = (0..<35).map { index in
            "sender-\(index)@example.com"
        }
        let (_, messages) = try makeConversationWithMessages(senderEmails: senderEmails)
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var prefetchedMessageBatches: [[String]] = []
        var prefetchedSenderEmailBatches: [[String]] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {},
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {},
            prefetchRecentContent: { messageIds, senderEmails in
                prefetchedMessageBatches.append(messageIds)
                prefetchedSenderEmailBatches.append(senderEmails)
            },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { _ in [:] },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { _ in }
        )

        coordinator.handleDisplayedMessagesChange(
            oldIDs: [],
            newIDs: rows.map(\.objectID),
            visibleMessages: rows,
            senderGroupingMessages: rows,
            messageCount: messages.count
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            prefetchedMessageBatches.count == 1 && anchorSteps.count == 5
        }

        let expectedPrefetchMessages = Array(messages.suffix(30))
        XCTAssertEqual(prefetchedMessageBatches, [expectedPrefetchMessages.map(\.id)])
        XCTAssertEqual(prefetchedSenderEmailBatches, [expectedPrefetchMessages.compactMap(\.senderEmail)])
    }

    func testHandleAppear_refreshesGroupingAcrossVisibleWindowBoundary() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "alice+work@example.com",
            "alice+personal@example.com",
            "alice@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var groupingRequests: [[String]] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {},
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {},
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { senderEmails in
                groupingRequests.append(senderEmails)
                return [
                    "alice+work@example.com": "group:alice@example.com",
                    "alice+personal@example.com": "group:alice@example.com",
                    "alice@example.com": "group:alice@example.com"
                ]
            },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { _ in }
        )

        coordinator.handleAppear(
            messageCount: rows.count,
            lastMessage: messages.last,
            visibleMessages: Array(rows.prefix(2)),
            senderGroupingMessages: Array(rows.prefix(3)),
            totalMessageCount: rows.count
        ) { _ in }

        await waitUntil {
            groupingRequests.count == 1
        }

        XCTAssertEqual(
            groupingRequests,
            [["alice+work@example.com", "alice+personal@example.com", "alice@example.com"]]
        )
        XCTAssertFalse(
            ChatMessageRowGrouping.isLastFromSender(
                current: rows[1],
                next: rows[2],
                senderRunKey: { message in
                    coordinator.senderRunKey(
                        for: message,
                        isEffectivelyOneToOneConversation: true
                    )
                }
            )
        )
    }

    func testHandlePersonDisplayInfoDidChangeRefreshesSenderDependentState() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "info@bonbonwhims.com",
            "other@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var loadResolvedDisplayNameCount = 0
        var groupingRequests: [[String]] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {},
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {
                loadResolvedDisplayNameCount += 1
            },
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { senderEmails in
                groupingRequests.append(senderEmails)
                return Dictionary(
                    uniqueKeysWithValues: senderEmails.map { email in
                        let normalizedEmail = EmailNormalizer.normalize(email)
                        return (normalizedEmail, "group:\(normalizedEmail)")
                    }
                )
            },
            invalidateContactsCache: {
                XCTFail("Internal person refresh should not clear the full contacts cache")
            },
            clearPersonCache: {
                XCTFail("Internal person refresh should not clear the full person cache")
            },
            sleep: { _ in }
        )

        coordinator.handlePersonDisplayInfoDidChange(senderGroupingMessages: rows)

        XCTAssertEqual(coordinator.contactRefreshToken, 1)
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        await waitUntil {
            groupingRequests.count == 1
        }
        XCTAssertEqual(groupingRequests, [["info@bonbonwhims.com", "other@example.com"]])
    }

    func testHandleMessageCountChange_afterReadyRequestsAnimatedBottomAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var updatedReplyTargets: [String?] = []
        var loadResolvedDisplayNameCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {
                loadLatestWindowCount += 1
            },
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { lastMessage in
                updatedReplyTargets.append(lastMessage?.id)
            },
            loadResolvedDisplayName: {
                loadResolvedDisplayNameCount += 1
            },
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { _ in [:] },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { _ in }
        )

        coordinator.handleAppear(
            messageCount: 1,
            lastMessage: messages.first,
            visibleMessages: [rows.first].compactMap { $0 },
            senderGroupingMessages: [rows.first].compactMap { $0 },
            totalMessageCount: 1
        ) { _ in
            XCTFail("Single-message appear should not schedule bottom anchoring")
        }

        await waitUntil {
            coordinator.isReadyToShow
        }

        loadLatestWindowCount = 0
        loadResolvedDisplayNameCount = 0

        coordinator.handleMessageCountChange(
            oldCount: 1,
            newCount: 2,
            lastMessage: messages.last,
            stabilizeBottomAnchor: false
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 1)
        XCTAssertEqual(updatedReplyTargets, [messages.last?.id])
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                )
            ]
        )
    }

    func testHandleMessageCountChange_withActiveComposerAddsStabilizationScroll() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {
                loadLatestWindowCount += 1
            },
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {},
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { _ in [:] },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { _ in }
        )

        coordinator.handleAppear(
            messageCount: 1,
            lastMessage: messages.first,
            visibleMessages: [rows.first].compactMap { $0 },
            senderGroupingMessages: [rows.first].compactMap { $0 },
            totalMessageCount: 1
        ) { _ in
            XCTFail("Single-message appear should not schedule bottom anchoring")
        }

        await waitUntil {
            coordinator.isReadyToShow
        }

        coordinator.handleMessageCountChange(
            oldCount: 1,
            newCount: 2,
            lastMessage: messages.last,
            stabilizeBottomAnchor: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 2
        }

        XCTAssertEqual(loadLatestWindowCount, 1)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                ),
                .init(
                    delay: max(UIConfig.initialScrollDelay, UIConfig.scrollAnimationDuration),
                    animated: false,
                    logMessage: "ChatView stabilization scroll after content change -> bottom anchor"
                )
            ]
        )
    }

    func testKeyboardAndFocusChanges_requestExpectedBottomAnchors() async {
        var loadLatestWindowCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {
                loadLatestWindowCount += 1
            },
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {},
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { _ in [:] },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { _ in }
        )

        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: 2
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 1)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                )
            ]
        )

        anchorSteps.removeAll()

        coordinator.handleKeyboardHeightChange(
            oldHeight: 240,
            newHeight: 0,
            messageCount: 2
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 2)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                )
            ]
        )

        anchorSteps.removeAll()

        coordinator.handleTextFieldFocusChange(
            isFocused: false,
            messageCount: 2
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 3)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: UIConfig.initialScrollDelay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                )
            ]
        )
    }

    func testKeyboardChangeDuringInitialLoad_doesNotBlockReadyStateOrFutureAnimatedScrolls() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {},
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {},
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { _ in [:] },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count
        ) { step in
            anchorSteps.append(step)
        }

        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: messages.count
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil(timeout: 1.0) {
            coordinator.isReadyToShow
        }

        XCTAssertTrue(
            anchorSteps.contains { $0.logMessage == "ChatView follow-up scroll -> bottom anchor" }
        )

        let animatedScrollCount = anchorSteps.filter {
            $0.logMessage == "ChatView animated scroll -> bottom anchor"
        }.count

        coordinator.handleMessageCountChange(
            oldCount: messages.count,
            newCount: messages.count + 1,
            lastMessage: messages.last,
            stabilizeBottomAnchor: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil(timeout: 1.0) {
            anchorSteps.contains {
                $0.logMessage == "ChatView stabilization scroll after content change -> bottom anchor"
            }
        }

        XCTAssertEqual(
            anchorSteps.filter { $0.logMessage == "ChatView animated scroll -> bottom anchor" }.count,
            animatedScrollCount + 1
        )
    }

    func testHandleContactStoreDidChange_refreshesCachesAndSenderGrouping() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "Alice@Example.com",
            "alice@example.com",
            "bob@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var invalidateContactsCacheCount = 0
        var clearPersonCacheCount = 0
        var loadResolvedDisplayNameCount = 0
        var groupingRequests: [[String]] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: {},
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {
                loadResolvedDisplayNameCount += 1
            },
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { senderEmails in
                groupingRequests.append(senderEmails)
                return Dictionary(
                    uniqueKeysWithValues: senderEmails.map { email in
                        let normalizedEmail = EmailNormalizer.normalize(email)
                        return (normalizedEmail, "group:\(normalizedEmail)")
                    }
                )
            },
            invalidateContactsCache: {
                invalidateContactsCacheCount += 1
            },
            clearPersonCache: {
                clearPersonCacheCount += 1
            },
            sleep: { _ in }
        )

        coordinator.handleContactStoreDidChange(senderGroupingMessages: rows)

        await waitUntil {
            coordinator.contactRefreshToken == 1 &&
                groupingRequests.count == 1
        }

        XCTAssertEqual(invalidateContactsCacheCount, 1)
        XCTAssertEqual(clearPersonCacheCount, 1)
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertEqual(groupingRequests, [["Alice@Example.com", "bob@example.com"]])
        XCTAssertEqual(
            coordinator.senderRunKey(
                for: rows[0],
                isEffectivelyOneToOneConversation: true
            ),
            "group:alice@example.com"
        )
    }

    private func makeConversationWithMessages(
        senderEmails: [String]
    ) throws -> (Conversation, [Message]) {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)

        var messages: [Message] = []
        for (index, senderEmail) in senderEmails.enumerated() {
            let message = MessageBuilder()
                .withId("chat-message-\(index)")
                .withSubject("Message \(index)")
                .withDate(Date(timeIntervalSince1970: TimeInterval(index)))
                .withSender(email: senderEmail)
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
