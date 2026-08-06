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

    func testTopPresentation_revealsLoadedRowsWithoutLoadingLatestOrScrolling() throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var latestWindowRequests: [Int?] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            initialPresentationAnchor: .top,
            loadLatestWindowIfNeeded: { knownTotalCount in
                latestWindowRequests.append(knownTotalCount)
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

        let geometryCheckBeforeAppear = coordinator.initialAnchorGeometryCheckID
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertTrue(latestWindowRequests.isEmpty)
        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertEqual(
            coordinator.initialAnchorGeometryCheckID,
            geometryCheckBeforeAppear
        )

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(anchorSteps.isEmpty)
    }

    func testTopPresentation_initialCountPublicationPreservesBeginningWindow() throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var latestWindowRequests: [Int?] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            initialPresentationAnchor: .top,
            loadLatestWindowIfNeeded: { knownTotalCount in
                latestWindowRequests.append(knownTotalCount)
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
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: [],
            senderGroupingMessages: [],
            totalMessageCount: messages.count,
            isInitialWindowLoaded: false
        ) { step in
            anchorSteps.append(step)
        }
        XCTAssertFalse(coordinator.isReadyToShow)

        coordinator.handleMessageCountChange(
            oldCount: 0,
            newCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            totalMessageCount: messages.count,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: false,
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertTrue(latestWindowRequests.isEmpty)
        XCTAssertTrue(anchorSteps.isEmpty)
    }

    func testTopPresentation_incomingMessageOnlyFollowsWhenBottomIsVisible() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var latestWindowRequests: [Int?] = []
        var updatedReplyTargets: [String?] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            initialPresentationAnchor: .top,
            loadLatestWindowIfNeeded: { knownTotalCount in
                latestWindowRequests.append(knownTotalCount)
            },
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { lastMessage in
                updatedReplyTargets.append(lastMessage?.id)
            },
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
            lastMessage: messages[0],
            visibleMessages: [rows[0]],
            senderGroupingMessages: [rows[0]],
            totalMessageCount: 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(coordinator.isReadyToShow)

        coordinator.handleMessageCountChange(
            oldCount: 1,
            newCount: 2,
            lastMessage: messages[1],
            visibleMessages: Array(rows.prefix(2)),
            totalMessageCount: 2,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(latestWindowRequests.isEmpty)
        XCTAssertEqual(updatedReplyTargets, [messages[1].id])
        XCTAssertTrue(anchorSteps.isEmpty)

        coordinator.handleMessageCountChange(
            oldCount: 2,
            newCount: 3,
            lastMessage: messages[2],
            visibleMessages: rows,
            totalMessageCount: 3,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(latestWindowRequests, [3, 3])
        XCTAssertEqual(updatedReplyTargets, [messages[1].id, messages[2].id])
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

    func testHandleAppear_waitsForLayoutConfirmationAndRefreshesGrouping() async throws {
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
            loadLatestWindowIfNeeded: { _ in
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

        let geometryCheckBeforeAppear = coordinator.initialAnchorGeometryCheckID
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            loadLatestWindowCount == 1 && groupingRequests.count == 1
        }

        XCTAssertFalse(coordinator.isReadyToShow)
        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertNotEqual(
            coordinator.initialAnchorGeometryCheckID,
            geometryCheckBeforeAppear
        )

        let geometryCheckBeforeScroll = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }
        XCTAssertFalse(coordinator.isReadyToShow)
        await waitUntil {
            coordinator.initialAnchorGeometryCheckID != geometryCheckBeforeScroll
        }
        XCTAssertNotEqual(
            coordinator.initialAnchorGeometryCheckID,
            geometryCheckBeforeScroll
        )

        await confirmInitialBottomAnchor(coordinator)

        XCTAssertEqual(loadLatestWindowCount, 1)
        XCTAssertTrue(coordinator.isReadyToShow)
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
            [UInt64(UIConfig.initialScrollDelay * 1_000_000_000)]
        )
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout scroll -> bottom anchor"
                )
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

    func testHandleAppear_defersInitialBottomAnchorUntilInitialWindowLoaded() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var markConversationAsReadCount = 0
        var initializedReplyTargets: [String?] = []
        var loadResolvedDisplayNameCount = 0
        var prefetchedMessageBatches: [[String]] = []
        var groupingRequests: [[String]] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in
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
            prefetchRecentContent: { messageIds, _ in
                prefetchedMessageBatches.append(messageIds)
            },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { senderEmails in
                groupingRequests.append(senderEmails)
                return [:]
            },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: { _ in }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: [],
            senderGroupingMessages: [],
            totalMessageCount: 0,
            isInitialWindowLoaded: false
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            groupingRequests.count == 1
        }

        XCTAssertFalse(coordinator.isReadyToShow)
        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertEqual(loadLatestWindowCount, 0)
        XCTAssertEqual(markConversationAsReadCount, 1)
        XCTAssertEqual(initializedReplyTargets, [messages.last?.id])
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertEqual(prefetchedMessageBatches, [[]])
        XCTAssertEqual(groupingRequests, [[]])

        coordinator.handleInitialWindowLoaded(
            messageCount: messages.count,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            loadLatestWindowCount == 1
        }

        XCTAssertFalse(coordinator.isReadyToShow)
        var geometryCheckID = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }
        await waitUntil {
            coordinator.initialAnchorGeometryCheckID != geometryCheckID
        }
        geometryCheckID = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertEqual(loadLatestWindowCount, 1)
        XCTAssertFalse(coordinator.isReadyToShow)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout scroll -> bottom anchor"
                ),
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout retry -> bottom anchor"
                )
            ]
        )

        await waitUntil {
            coordinator.initialAnchorGeometryCheckID != geometryCheckID
        }
        await confirmInitialBottomAnchor(coordinator)
        XCTAssertTrue(coordinator.isReadyToShow)
    }

    func testPermanentlyOffscreenInitialAnchorStopsAfterBoundedRetriesAndReveals() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        for _ in 0..<2 {
            let geometryCheckID = coordinator.initialAnchorGeometryCheckID
            coordinator.handleBottomAnchorGeometryUpdate(
                isBottomAnchorVisible: false
            ) { step in
                anchorSteps.append(step)
            }
            XCTAssertFalse(coordinator.isReadyToShow)
            await waitUntil {
                coordinator.initialAnchorGeometryCheckID != geometryCheckID
            }
        }

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { _ in
            XCTFail("Exhausting initial retries must not issue a third scroll")
        }

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout scroll -> bottom anchor"
                ),
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout retry -> bottom anchor"
                )
            ]
        )

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true
        ) { _ in
            XCTFail("Fallback reveal must not activate post-reveal following")
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { _ in
            XCTFail("Fallback reveal must make initial anchoring terminal")
        }
    }

    func testSynchronousVisibleGeometryDuringScrollPreservesConfirmationTimer() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var sleepCalls: [UInt64] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            sleep: { nanoseconds in
                sleepCalls.append(nanoseconds)
            }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        let geometryCheckID = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
            coordinator.handleBottomAnchorGeometryUpdate(
                isBottomAnchorVisible: true
            ) { _ in
                XCTFail("Reentrant visible geometry must not request another scroll")
            }
        }

        await waitUntil {
            sleepCalls.count == 1
                && coordinator.initialAnchorGeometryCheckID != geometryCheckID
        }
        XCTAssertFalse(coordinator.isReadyToShow)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true
        ) { _ in
            XCTFail("Stable visible geometry must not request another scroll")
        }

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertEqual(
            sleepCalls,
            [UInt64(UIConfig.initialScrollDelay * 1_000_000_000)]
        )
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout scroll -> bottom anchor"
                )
            ]
        )
    }

    func testVisiblyConfirmedRevealRetriesConsecutiveOffscreenLayoutsUntilVisible() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var sleepCalls: [UInt64] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            sleep: { nanoseconds in
                sleepCalls.append(nanoseconds)
            }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)
        XCTAssertTrue(coordinator.isReadyToShow)
        sleepCalls.removeAll()

        let geometryCheckID = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 120
        ) { step in
            anchorSteps.append(step)
            coordinator.handleBottomAnchorGeometryUpdate(
                isBottomAnchorVisible: false,
                contentMinY: 0,
                contentHeight: 120
            ) { _ in
                XCTFail("A reentrant repeated offscreen callback must not scroll again")
            }
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 160
        ) { _ in
            XCTFail("A consecutive resize should be coalesced into the pending geometry check")
        }

        await waitUntil {
            anchorSteps.count == 2 && sleepCalls.count == 2
        }

        XCTAssertEqual(coordinator.initialAnchorGeometryCheckID, geometryCheckID)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView post-reveal layout scroll -> bottom anchor"
                ),
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView post-reveal layout retry -> bottom anchor"
                )
            ]
        )

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            contentMinY: -60,
            contentHeight: 160
        ) { _ in
            XCTFail("Returning onscreen must not request a scroll")
        }
        coordinator.handleUserScrollInteraction()
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: -60,
            contentHeight: 200
        ) { _ in
            XCTFail("User interaction must cancel post-reveal bottom following")
        }

        XCTAssertEqual(anchorSteps.count, 2)
    }

    func testPostRevealBottomFollowDoesNotOverrideNonLayoutScroll() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 100,
            contentHeight: 140
        ) { _ in
            XCTFail("Content moving toward history must be treated as user scrolling")
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 100,
            contentHeight: 180
        ) { _ in
            XCTFail("Cancelled following must not resume after later layout growth")
        }
    }

    func testPostRevealBottomFollowRespondsToViewportShrink() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 100,
            viewportHeight: 80
        ) { step in
            anchorSteps.append(step)
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            contentMinY: -20,
            contentHeight: 100,
            viewportHeight: 80
        ) { _ in
            XCTFail("Returning onscreen after a viewport resize must not request a scroll")
        }

        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView post-reveal layout scroll -> bottom anchor"
                )
            ]
        )
    }

    func testPostRevealBottomFollowExpiresAfterGracePeriod() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var currentTime: TimeInterval = 1_000
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            now: { currentTime }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 120
        ) { step in
            anchorSteps.append(step)
        }
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            contentMinY: -20,
            contentHeight: 120
        ) { _ in
            XCTFail("Returning onscreen must not request a scroll")
        }

        currentTime += 3.1
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: -20,
            contentHeight: 140
        ) { _ in
            XCTFail("Expired post-reveal following must not override later scrolling")
        }

        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView post-reveal layout scroll -> bottom anchor"
                )
            ]
        )
    }

    func testPostRevealBottomFollowStopsOnDisappear() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleDisappear()
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { _ in
            XCTFail("Disappearing must cancel post-reveal bottom following")
        }
    }

    func testUserScrollDuringPendingStabilizationCancelsForcedAnchoring() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }

        XCTAssertFalse(coordinator.isReadyToShow)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true
        ) { _ in
            XCTFail("A visible anchor should begin confirmation without scrolling")
        }
        XCTAssertFalse(coordinator.isReadyToShow)

        coordinator.handleUserScrollInteraction()

        XCTAssertTrue(coordinator.isReadyToShow)
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { _ in
            XCTFail("User interaction must cancel later initial scroll attempts")
        }
    }

    func testUserScrollDuringInitialRevealCancelsLatestWindowLoads() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com",
            "fourth@example.com"
        ])
        let visibleRows = messages.prefix(3).map { ChatMessageRowModelMapper.map($0) }
        let initialLoadStarted = expectation(description: "Initial latest-window load started")
        let refreshLoadStarted = expectation(description: "Arrival latest-window load started")
        let loadsCancelled = expectation(description: "Latest-window loads cancelled")
        loadsCancelled.expectedFulfillmentCount = 2
        let unexpectedRestart = expectation(
            description: "User takeover must prevent a later latest-window restart"
        )
        unexpectedRestart.isInverted = true
        var hasUserTakenOver = false
        var cancelledKnownCounts: [Int?] = []
        var completedKnownCounts: [Int?] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                if hasUserTakenOver {
                    unexpectedRestart.fulfill()
                    return
                }
                if knownTotalCount == nil {
                    initialLoadStarted.fulfill()
                } else if knownTotalCount == 4 {
                    refreshLoadStarted.fulfill()
                }

                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    completedKnownCounts.append(knownTotalCount)
                } catch {
                    guard Task.isCancelled else { return }
                    cancelledKnownCounts.append(knownTotalCount)
                    loadsCancelled.fulfill()
                }
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
            messageCount: 3,
            lastMessage: messages[2],
            visibleMessages: visibleRows,
            senderGroupingMessages: visibleRows,
            totalMessageCount: 3,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        await fulfillment(of: [initialLoadStarted], timeout: 1)

        coordinator.handleMessageCountChange(
            oldCount: 3,
            newCount: 4,
            lastMessage: messages[3],
            visibleMessages: visibleRows,
            totalMessageCount: 4,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }
        await fulfillment(of: [refreshLoadStarted], timeout: 1)

        coordinator.handleUserScrollInteraction()
        await fulfillment(of: [loadsCancelled], timeout: 1)

        hasUserTakenOver = true
        coordinator.handleMessageCountChange(
            oldCount: 3,
            newCount: 4,
            lastMessage: messages[3],
            visibleMessages: visibleRows,
            totalMessageCount: 4,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }
        await fulfillment(of: [unexpectedRestart], timeout: 0.1)

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertEqual(
            cancelledKnownCounts.map { $0 ?? -1 }.sorted(),
            [-1, 4]
        )
        XCTAssertTrue(completedKnownCounts.isEmpty)
    }

    func testBottomMovingOffscreenDuringStabilizationReanchorsAndRequiresFreshConfirmation() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }
        XCTAssertFalse(coordinator.isReadyToShow)

        let geometryCheckBeforeReanchor = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertFalse(coordinator.isReadyToShow)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout scroll -> bottom anchor"
                )
            ]
        )
        await waitUntil {
            coordinator.initialAnchorGeometryCheckID != geometryCheckBeforeReanchor
        }

        let geometryCheckBeforeConfirmation = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }
        await waitUntil {
            coordinator.initialAnchorGeometryCheckID != geometryCheckBeforeConfirmation
        }
        XCTAssertFalse(coordinator.isReadyToShow)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertEqual(anchorSteps.count, 1)
    }

    func testTransientReappearanceDoesNotRecaptureUnreadOrConsumeHiddenArrival() {
        var markConversationAsReadCount = 0
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: { markConversationAsReadCount += 1 },
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let arrivalID = makeMessageObjectID("hidden-arrival")

        handleEmptyAppear(coordinator)
        coordinator.handleDisappear()
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        handleRefreshAndLayout(
            coordinator,
            event: event,
            messageIDsInLatestWindow: [arrivalID]
        )
        handleEmptyAppear(coordinator)

        XCTAssertEqual(markConversationAsReadCount, 1)
        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalAtLatestVisibleWindowAfterReadyMarksUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let arrivalID = makeMessageObjectID("visible-arrival")
        handleEmptyAppear(coordinator)

        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        XCTAssertTrue(markedArrivalIDs.isEmpty)

        let layoutID = UUID()
        coordinator.handleRefreshedInsertedMessageEvent(
            .init(
                eventID: event.id,
                layoutID: layoutID,
                messageIDsInLatestWindow: [arrivalID]
            ),
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true
        )
        XCTAssertTrue(markedArrivalIDs.isEmpty)

        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )

        XCTAssertEqual(markedArrivalIDs, [[arrivalID]])
    }

    func testArrivalWhileScrolledUpDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        handleEmptyAppear(coordinator)

        let arrivalID = makeMessageObjectID("scrolled-arrival")
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: false
        )
        handleRefreshAndLayout(
            coordinator,
            event: event,
            messageIDsInLatestWindow: [arrivalID]
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalBeforeChatIsReadyDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        coordinator.handleAppear(
            messageCount: 2,
            lastMessage: nil,
            visibleMessages: [],
            senderGroupingMessages: [],
            totalMessageCount: 2,
            isInitialWindowLoaded: false
        ) { _ in }

        let arrivalID = makeMessageObjectID("pre-ready-arrival")
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        handleRefreshAndLayout(
            coordinator,
            event: event,
            messageIDsInLatestWindow: [arrivalID]
        )

        XCTAssertFalse(coordinator.isReadyToShow)
        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalWhileChatIsCoveredOrInactiveDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        handleEmptyAppear(coordinator)

        let arrivalID = makeMessageObjectID("covered-arrival")
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: false,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        handleRefreshAndLayout(
            coordinator,
            event: event,
            messageIDsInLatestWindow: [arrivalID]
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalExcludedFromRefreshedLatestWindowDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let event = VirtualScrollInsertedMessageEvent(
            id: UUID(),
            messageIDs: [makeMessageObjectID("historical-arrival")]
        )
        handleEmptyAppear(coordinator)

        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        handleRefreshAndLayout(
            coordinator,
            event: event,
            messageIDsInLatestWindow: []
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalThatBecomesCoveredBeforeRefreshDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let arrivalID = makeMessageObjectID("covered-during-refresh")
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        handleEmptyAppear(coordinator)

        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        handleRefreshAndLayout(
            coordinator,
            event: event,
            messageIDsInLatestWindow: [arrivalID],
            isChatActiveAtRefresh: false
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalThatPushesBottomAnchorOffscreenAfterRefreshDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let arrivalID = makeMessageObjectID("offscreen-after-layout")
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        let layoutID = UUID()
        handleEmptyAppear(coordinator)

        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        coordinator.handleRefreshedInsertedMessageEvent(
            .init(
                eventID: event.id,
                layoutID: layoutID,
                messageIDsInLatestWindow: [arrivalID]
            ),
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)

        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: false
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testArrivalThatBecomesCoveredBeforeLayoutDoesNotMarkUnreadAsRead() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let arrivalID = makeMessageObjectID("covered-before-layout")
        let event = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [arrivalID])
        let layoutID = UUID()
        handleEmptyAppear(coordinator)

        coordinator.handleInsertedVisibleMessageEvent(
            event,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )
        coordinator.handleRefreshedInsertedMessageEvent(
            .init(
                eventID: event.id,
                layoutID: layoutID,
                messageIDsInLatestWindow: [arrivalID]
            ),
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true
        )
        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: false,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )

        XCTAssertTrue(markedArrivalIDs.isEmpty)
    }

    func testRapidArrivalEventsAreResolvedIndependently() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let firstID = makeMessageObjectID("first-rapid-arrival")
        let secondID = makeMessageObjectID("second-rapid-arrival")
        let firstEvent = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [firstID])
        let secondEvent = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [secondID])
        handleEmptyAppear(coordinator)

        for event in [firstEvent, secondEvent] {
            coordinator.handleInsertedVisibleMessageEvent(
                event,
                isChatActiveAndUncovered: true,
                isShowingLatestWindow: true,
                isBottomAnchorVisible: true
            )
        }
        let layoutID = UUID()
        for event in [firstEvent, secondEvent] {
            coordinator.handleRefreshedInsertedMessageEvent(
                .init(
                    eventID: event.id,
                    layoutID: layoutID,
                    messageIDsInLatestWindow: event.messageIDs
                ),
                isChatActiveAndUncovered: true,
                isShowingLatestWindow: true
            )
        }
        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )

        XCTAssertEqual(markedArrivalIDs, [[firstID, secondID]])
    }

    func testNewerLayoutResolvesEarlierPendingLayoutBatches() {
        var markedArrivalIDs: [[NSManagedObjectID]] = []
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { markedArrivalIDs.append($0) }
        )
        let firstID = makeMessageObjectID("first-layout-arrival")
        let secondID = makeMessageObjectID("second-layout-arrival")
        let firstEvent = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [firstID])
        let secondEvent = VirtualScrollInsertedMessageEvent(id: UUID(), messageIDs: [secondID])
        handleEmptyAppear(coordinator)

        for event in [firstEvent, secondEvent] {
            coordinator.handleInsertedVisibleMessageEvent(
                event,
                isChatActiveAndUncovered: true,
                isShowingLatestWindow: true,
                isBottomAnchorVisible: true
            )
        }
        let firstLayoutID = UUID()
        coordinator.handleRefreshedInsertedMessageEvent(
            .init(eventID: firstEvent.id, layoutID: firstLayoutID, messageIDsInLatestWindow: [firstID]),
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true
        )
        let secondLayoutID = UUID()
        coordinator.handleRefreshedInsertedMessageEvent(
            .init(eventID: secondEvent.id, layoutID: secondLayoutID, messageIDsInLatestWindow: [secondID]),
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true
        )

        coordinator.handleLatestWindowLayout(
            layoutID: secondLayoutID,
            isChatActiveAndUncovered: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        )

        XCTAssertEqual(markedArrivalIDs, [[firstID, secondID]])
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
            loadLatestWindowIfNeeded: { _ in },
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
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            prefetchedMessageBatches.count == 1
        }

        XCTAssertTrue(anchorSteps.isEmpty)
        let expectedPrefetchMessages = Array(messages.suffix(30))
        XCTAssertEqual(prefetchedMessageBatches, [expectedPrefetchMessages.map(\.id)])
        XCTAssertEqual(prefetchedSenderEmailBatches, [expectedPrefetchMessages.compactMap(\.senderEmail)])
    }

    func testHandleDisplayedMessagesChange_prefetchesOnlyMessagesMissingChatPreviewText() async throws {
        let senderEmails = [
            "has-preview@example.com",
            "blank-preview@example.com",
            "missing-preview@example.com",
            "also-has-preview@example.com"
        ]
        let (_, messages) = try makeConversationWithMessages(senderEmails: senderEmails)
        messages[0].chatPreviewText = "Stored chat preview"
        messages[1].chatPreviewText = " \n\t "
        messages[2].chatPreviewText = nil
        messages[3].chatPreviewText = "Another stored preview"
        try viewContext.save()
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var prefetchedMessageBatches: [[String]] = []
        var prefetchedSenderEmailBatches: [[String]] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in },
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
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }

        await waitUntil {
            prefetchedMessageBatches.count == 1
        }

        XCTAssertEqual(prefetchedMessageBatches, [[messages[1].id, messages[2].id]])
        XCTAssertEqual(prefetchedSenderEmailBatches, [senderEmails])
    }

    func testScrollHandlers_doNotScheduleBottomAnchorsBeforeInitialWindowLoaded() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])

        var loadLatestWindowCount = 0
        var loadResolvedDisplayNameCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in
                loadLatestWindowCount += 1
            },
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
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

        coordinator.handleMessageCountChange(
            oldCount: 2,
            newCount: 3,
            lastMessage: messages.last,
            visibleMessages: [],
            totalMessageCount: 0,
            stabilizeBottomAnchor: true,
            isInitialWindowLoaded: false,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: 3,
            isInitialWindowLoaded: false
        ) { step in
            anchorSteps.append(step)
        }

        coordinator.handleTextFieldFocusChange(
            isFocused: false,
            messageCount: 3,
            isInitialWindowLoaded: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertEqual(loadLatestWindowCount, 0)
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertFalse(coordinator.isReadyToShow)
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
            loadLatestWindowIfNeeded: { _ in },
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
            totalMessageCount: rows.count,
            isInitialWindowLoaded: true
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
            loadLatestWindowIfNeeded: { _ in },
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

    func testHandleMessageCountChange_emptyToLoadedUsesAlreadyPublishedRows() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var latestWindowKnownCounts: [Int?] = []
        var updatedReplyTargets: [String?] = []
        var loadResolvedDisplayNameCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                latestWindowKnownCounts.append(knownTotalCount)
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
            messageCount: 0,
            lastMessage: nil,
            visibleMessages: [],
            senderGroupingMessages: [],
            totalMessageCount: 0,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("Empty appear should not schedule bottom anchoring")
        }

        XCTAssertTrue(coordinator.isReadyToShow)
        loadResolvedDisplayNameCount = 0

        coordinator.handleMessageCountChange(
            oldCount: 0,
            newCount: 2,
            lastMessage: messages.last,
            visibleMessages: rows,
            totalMessageCount: 2,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            latestWindowKnownCounts.contains(2)
        }

        await confirmInitialBottomAnchor(coordinator)

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertEqual(updatedReplyTargets, [messages.last?.id])
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertTrue(anchorSteps.isEmpty)
    }

    func testHandleMessageCountChange_duringInitialRevealRefreshesLatestWindowWithNewCount() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com",
            "fourth@example.com"
        ])
        let visibleRows = messages.prefix(3).map { ChatMessageRowModelMapper.map($0) }

        var latestWindowKnownCounts: [Int?] = []
        var loadResolvedDisplayNameCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                latestWindowKnownCounts.append(knownTotalCount)
            },
            markConversationAsReadIfNeeded: {},
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
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
            messageCount: 3,
            lastMessage: messages[2],
            visibleMessages: visibleRows,
            senderGroupingMessages: visibleRows,
            totalMessageCount: 3,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertFalse(coordinator.isReadyToShow)
        loadResolvedDisplayNameCount = 0

        coordinator.handleMessageCountChange(
            oldCount: 3,
            newCount: 4,
            lastMessage: messages[3],
            visibleMessages: visibleRows,
            totalMessageCount: 3,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            latestWindowKnownCounts.contains(4)
        }

        await confirmInitialBottomAnchor(coordinator)

        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
        XCTAssertTrue(anchorSteps.isEmpty)
    }

    func testHandleMessageCountChange_afterReadyRequestsAnimatedBottomAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var latestWindowKnownCounts: [Int?] = []
        var updatedReplyTargets: [String?] = []
        var loadResolvedDisplayNameCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                loadLatestWindowCount += 1
                latestWindowKnownCounts.append(knownTotalCount)
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
            totalMessageCount: 1,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("Single-message appear should not require a bottom scroll")
        }

        await confirmInitialBottomAnchor(coordinator)

        loadLatestWindowCount = 0
        loadResolvedDisplayNameCount = 0

        coordinator.handleMessageCountChange(
            oldCount: 1,
            newCount: 2,
            lastMessage: messages.last,
            visibleMessages: rows,
            totalMessageCount: 2,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 2)
        XCTAssertEqual(latestWindowKnownCounts, [2, 2])
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

    func testBottomPresentationUserTakeoverRejectsStaleBottomUntilGeometryReconfirms() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let unexpectedLatestLoad = expectation(
            description: "Incoming message must not reload the latest window"
        )
        unexpectedLatestLoad.isInverted = true
        let firstTakeoverReleaseSleepStarted = expectation(
            description: "First takeover release settle delay started"
        )
        let firstTakeoverReleaseSleepCancelled = expectation(
            description: "Continued visible scrolling cancelled first release delay"
        )
        let replacementTakeoverReleaseSleepStarted = expectation(
            description: "Replacement takeover release settle delay started"
        )
        let replacementTakeoverReleaseSleepCancelled = expectation(
            description: "Further visible scrolling cancelled replacement release delay"
        )
        var isRejectingLatestLoads = false
        var isTrackingTakeoverReleaseSleeps = false
        var takeoverReleaseSleepDelays: [UInt64] = []
        var latestWindowKnownCounts: [Int?] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                if isRejectingLatestLoads {
                    unexpectedLatestLoad.fulfill()
                } else {
                    latestWindowKnownCounts.append(knownTotalCount)
                }
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
            sleep: { delay in
                guard isTrackingTakeoverReleaseSleeps else { return }
                takeoverReleaseSleepDelays.append(delay)
                let invocation = takeoverReleaseSleepDelays.count
                guard invocation <= 2 else { return }
                if invocation == 1 {
                    firstTakeoverReleaseSleepStarted.fulfill()
                } else {
                    replacementTakeoverReleaseSleepStarted.fulfill()
                }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    guard Task.isCancelled else { return }
                    if invocation == 1 {
                        firstTakeoverReleaseSleepCancelled.fulfill()
                    } else {
                        replacementTakeoverReleaseSleepCancelled.fulfill()
                    }
                }
            }
        )

        coordinator.handleAppear(
            messageCount: 1,
            lastMessage: messages[0],
            visibleMessages: [rows[0]],
            senderGroupingMessages: [rows[0]],
            totalMessageCount: 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        await confirmInitialBottomAnchor(coordinator)

        latestWindowKnownCounts.removeAll()
        isRejectingLatestLoads = true
        coordinator.handleUserScrollInteraction()
        coordinator.handleMessageCountChange(
            oldCount: 1,
            newCount: 2,
            lastMessage: messages[1],
            visibleMessages: rows,
            totalMessageCount: 2,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await fulfillment(of: [unexpectedLatestLoad], timeout: 0.1)
        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertTrue(coordinator.isUserScrollTakeoverActive)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            isUserScrollInteractionActive: true
        ) { _ in
            XCTFail("Active user scrolling must keep passive following disabled")
        }
        XCTAssertTrue(coordinator.isUserScrollTakeoverActive)

        isTrackingTakeoverReleaseSleeps = true
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            isUserScrollInteractionActive: false
        ) { _ in
            XCTFail("Bottom reconfirmation should wait for geometry to settle")
        }
        await fulfillment(of: [firstTakeoverReleaseSleepStarted], timeout: 1)
        XCTAssertTrue(coordinator.isUserScrollTakeoverActive)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            isUserScrollInteractionActive: false
        ) { _ in
            XCTFail("Continued visible geometry should restart the settle delay")
        }
        await fulfillment(
            of: [
                firstTakeoverReleaseSleepCancelled,
                replacementTakeoverReleaseSleepStarted
            ],
            timeout: 1
        )
        XCTAssertTrue(coordinator.isUserScrollTakeoverActive)

        isRejectingLatestLoads = false
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            isUserScrollInteractionActive: false
        ) { _ in
            XCTFail("Settled visible geometry should only re-enable passive following")
        }
        await fulfillment(of: [replacementTakeoverReleaseSleepCancelled], timeout: 1)
        await waitUntil {
            !coordinator.isUserScrollTakeoverActive
        }
        XCTAssertEqual(
            takeoverReleaseSleepDelays,
            Array(
                repeating: UInt64(UIConfig.initialScrollDelay * 1_000_000_000),
                count: 3
            )
        )
        coordinator.handleMessageCountChange(
            oldCount: 2,
            newCount: 3,
            lastMessage: messages[2],
            visibleMessages: rows,
            totalMessageCount: 3,
            stabilizeBottomAnchor: false,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }
        XCTAssertEqual(latestWindowKnownCounts, [3, 3])
    }

    func testHandleMessageCountChange_afterReadyAwayFromLatestDoesNotRequestBottomAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com",
            "third@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var updatedReplyTargets: [String?] = []
        var loadResolvedDisplayNameCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in
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
            visibleMessages: [rows[0]],
            senderGroupingMessages: [rows[0]],
            totalMessageCount: 1,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("Single-message appear should not require a bottom scroll")
        }

        await confirmInitialBottomAnchor(coordinator)
        loadResolvedDisplayNameCount = 0

        coordinator.handleMessageCountChange(
            oldCount: 8,
            newCount: 9,
            lastMessage: messages.last,
            visibleMessages: Array(rows.prefix(2)),
            totalMessageCount: 9,
            stabilizeBottomAnchor: true,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: false,
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertEqual(loadLatestWindowCount, 0)
        XCTAssertTrue(anchorSteps.isEmpty)
        XCTAssertTrue(updatedReplyTargets.isEmpty)
        XCTAssertEqual(loadResolvedDisplayNameCount, 1)
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
            loadLatestWindowIfNeeded: { _ in
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
            totalMessageCount: 1,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("Single-message appear should not require a bottom scroll")
        }

        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleMessageCountChange(
            oldCount: 1,
            newCount: 2,
            lastMessage: messages.last,
            visibleMessages: rows,
            totalMessageCount: 2,
            stabilizeBottomAnchor: true,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 2
        }

        XCTAssertEqual(loadLatestWindowCount, 3)
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

    func testHandleReplySendCompletedPublishesTargetBeforeStabilizedBottomAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var latestWindowKnownCounts: [Int?] = []
        var ensuredMessageIDs: [NSManagedObjectID] = []
        var presentationEvents: [String] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                latestWindowKnownCounts.append(knownTotalCount)
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
            sleep: { _ in },
            ensureVisibleMessage: { messageObjectID in
                ensuredMessageIDs.append(messageObjectID)
                presentationEvents.append("target-published")
                return true
            }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }

        await confirmInitialBottomAnchor(coordinator)
        XCTAssertTrue(coordinator.isReadyToShow)
        latestWindowKnownCounts.removeAll()

        let targetMessageID = messages.last!.objectID
        let anchorIntent = coordinator.capturePostSendAnchorIntent()
        coordinator.handleReplySendCompleted(
            targetMessageID: targetMessageID,
            anchorIntent: anchorIntent,
            messageCount: messages.count,
            totalMessageCount: messages.count + 1,
            isInitialWindowLoaded: true
        ) { step in
            presentationEvents.append("anchor")
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 2
        }

        XCTAssertEqual(ensuredMessageIDs, [targetMessageID])
        XCTAssertTrue(latestWindowKnownCounts.isEmpty)
        XCTAssertEqual(
            presentationEvents,
            ["target-published", "anchor", "anchor"]
        )
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

    func testHandleReplySendCompletedWaitsForExactTargetPublicationBeforeAnchoring() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let visibilityEnsureStarted = expectation(
            description: "Exact-message publication started"
        )
        var mayPublishTarget = false
        var didPublishTarget = false
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            ensureVisibleMessage: { messageObjectID in
                XCTAssertEqual(messageObjectID, messages.last!.objectID)
                visibilityEnsureStarted.fulfill()
                while !mayPublishTarget && !Task.isCancelled {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return false }
                didPublishTarget = true
                return true
            }
        )
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            XCTAssertTrue(
                didPublishTarget,
                "The exact target must publish before any anchor callback"
            )
            anchorSteps.append(step)
        }

        await fulfillment(of: [visibilityEnsureStarted], timeout: 1)
        XCTAssertFalse(didPublishTarget)
        XCTAssertTrue(anchorSteps.isEmpty)

        mayPublishTarget = true
        await waitUntil {
            anchorSteps.count == 2
        }
        XCTAssertTrue(didPublishTarget)
    }

    func testNewUserTakeoverDuringPostSendPublicationSuppressesOnlyAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let visibilityEnsureStarted = expectation(
            description: "Exact-message publication started"
        )
        let visibilityEnsureCompleted = expectation(
            description: "Exact-message publication completed"
        )
        let unexpectedAnchor = expectation(
            description: "A newer user interaction must suppress post-send anchoring"
        )
        unexpectedAnchor.isInverted = true
        var mayPublishTarget = false

        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            ensureVisibleMessage: { messageObjectID in
                XCTAssertEqual(messageObjectID, messages.last!.objectID)
                visibilityEnsureStarted.fulfill()
                while !mayPublishTarget && !Task.isCancelled {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return false }
                visibilityEnsureCompleted.fulfill()
                return true
            }
        )
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        let anchorIntent = coordinator.capturePostSendAnchorIntent()
        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: anchorIntent,
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            unexpectedAnchor.fulfill()
        }

        await fulfillment(of: [visibilityEnsureStarted], timeout: 1)
        coordinator.handleUserScrollInteraction()
        mayPublishTarget = true

        await fulfillment(
            of: [visibilityEnsureCompleted, unexpectedAnchor],
            timeout: 0.1
        )
        XCTAssertTrue(coordinator.isUserScrollTakeoverActive)
    }

    func testRapidReplyCompletionsKeepBothMandatoryPublicationTasks() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let visibilityEnsuresStarted = expectation(
            description: "Both exact-message publications started"
        )
        visibilityEnsuresStarted.expectedFulfillmentCount = 2
        let visibilityEnsuresCompleted = expectation(
            description: "Both exact-message publications completed"
        )
        visibilityEnsuresCompleted.expectedFulfillmentCount = 2
        let unexpectedAnchor = expectation(
            description: "Newer takeover must suppress both optional anchors"
        )
        unexpectedAnchor.isInverted = true
        var mayPublishTargets = false
        var publishedMessageIDs: [NSManagedObjectID] = []

        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            ensureVisibleMessage: { messageObjectID in
                visibilityEnsuresStarted.fulfill()
                while !mayPublishTargets && !Task.isCancelled {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return false }
                publishedMessageIDs.append(messageObjectID)
                visibilityEnsuresCompleted.fulfill()
                return true
            }
        )
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        let anchorIntent = coordinator.capturePostSendAnchorIntent()
        for message in messages {
            coordinator.handleReplySendCompleted(
                targetMessageID: message.objectID,
                anchorIntent: anchorIntent,
                messageCount: messages.count,
                totalMessageCount: messages.count,
                isInitialWindowLoaded: true
            ) { _ in
                unexpectedAnchor.fulfill()
            }
        }

        await fulfillment(of: [visibilityEnsuresStarted], timeout: 1)
        coordinator.handleUserScrollInteraction()
        mayPublishTargets = true

        await fulfillment(
            of: [visibilityEnsuresCompleted, unexpectedAnchor],
            timeout: 0.1
        )
        XCTAssertEqual(Set(publishedMessageIDs), Set(messages.map(\.objectID)))
    }

    func testFailedPostSendTargetPublicationDoesNotAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let visibilityEnsureCompleted = expectation(
            description: "Exact-message publication was attempted"
        )
        let unexpectedAnchor = expectation(
            description: "An absent target must not be reported as anchored"
        )
        unexpectedAnchor.isInverted = true

        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            ensureVisibleMessage: { messageObjectID in
                XCTAssertEqual(messageObjectID, messages.last!.objectID)
                visibilityEnsureCompleted.fulfill()
                return false
            }
        )
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            unexpectedAnchor.fulfill()
        }

        await fulfillment(
            of: [visibilityEnsureCompleted, unexpectedAnchor],
            timeout: 0.1
        )
    }

    func testReplySendCompletionRearmsBottomFollowForLateContentGrowth() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var currentTime: TimeInterval = 1_000
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            now: { currentTime }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)

        // The initial post-reveal grace has expired by the time a user reads,
        // types, and sends; late growth must be ignored at this point.
        currentTime += 3.1
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 140
        ) { _ in
            XCTFail("Expired initial grace must not follow late growth")
        }

        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count + 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        await waitUntil {
            anchorSteps.count == 2
        }

        // Content growing while the bottom anchor is offscreen — a bubble
        // re-resolving its body after the send — must now re-anchor.
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 700
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 4
        }
        XCTAssertEqual(
            Array(anchorSteps.suffix(2)),
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView post-reveal layout scroll -> bottom anchor"
                ),
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView post-reveal layout retry -> bottom anchor"
                )
            ]
        )
    }

    func testUserScrollAfterReplySendCancelsRearmedBottomFollow() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var currentTime: TimeInterval = 1_000
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            now: { currentTime }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)
        currentTime += 3.1
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 140
        ) { _ in
            XCTFail("Expired initial grace must not follow late growth")
        }

        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count + 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        await waitUntil {
            anchorSteps.count == 2
        }

        coordinator.handleUserScrollInteraction()
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 700
        ) { _ in
            XCTFail("User scrolling after a send must cancel the re-armed follow")
        }
        XCTAssertEqual(anchorSteps.count, 2)
    }

    func testRearmedBottomFollowExpiresAfterGracePeriod() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var currentTime: TimeInterval = 1_000
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            now: { currentTime }
        )
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)
        currentTime += 3.1
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 140
        ) { _ in
            XCTFail("Expired initial grace must not follow late growth")
        }

        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count + 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        await waitUntil {
            anchorSteps.count == 2
        }

        currentTime += 3.1
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 700
        ) { _ in
            XCTFail("The re-armed follow must expire after its grace period")
        }
        XCTAssertEqual(anchorSteps.count, 2)
    }

    func testFailedPostSendPublicationDoesNotRearmBottomFollow() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        var currentTime: TimeInterval = 1_000
        let visibilityEnsureCompleted = expectation(
            description: "Exact-message publication was attempted"
        )
        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            now: { currentTime },
            ensureVisibleMessage: { _ in
                visibilityEnsureCompleted.fulfill()
                return false
            }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("A visible initial anchor must not request a scroll")
        }
        await confirmInitialBottomAnchor(coordinator)
        currentTime += 3.1
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 140
        ) { _ in
            XCTFail("Expired initial grace must not follow late growth")
        }

        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("An unpublished target must not anchor")
        }
        await fulfillment(of: [visibilityEnsureCompleted], timeout: 1)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false,
            contentMinY: 0,
            contentHeight: 700
        ) { _ in
            XCTFail("A failed publication must not re-arm bottom following")
        }
    }

    func testUserTakeoverAfterPostSendPublicationCancelsOptionalAnchor() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let visibilityEnsureCompleted = expectation(
            description: "Exact-message publication completed"
        )
        let anchorDelayStarted = expectation(
            description: "Optional post-send anchor delay started"
        )
        let anchorDelayCancelled = expectation(
            description: "Optional post-send anchor delay was cancelled"
        )
        let unexpectedAnchor = expectation(
            description: "Cancelled optional anchor must not run"
        )
        unexpectedAnchor.isInverted = true
        var shouldBlockAnchorDelay = false
        var mayFinishAnchorDelay = false

        let coordinator = makeUnreadCoordinator(
            markConversationAsReadIfNeeded: {},
            markUnreadInboxMessagesAsReadIfNeeded: { _ in },
            sleep: { _ in
                guard shouldBlockAnchorDelay else { return }
                anchorDelayStarted.fulfill()
                while !mayFinishAnchorDelay && !Task.isCancelled {
                    await Task.yield()
                }
                if Task.isCancelled {
                    anchorDelayCancelled.fulfill()
                }
            },
            ensureVisibleMessage: { messageObjectID in
                XCTAssertEqual(messageObjectID, messages.last!.objectID)
                visibilityEnsureCompleted.fulfill()
                return true
            }
        )
        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        shouldBlockAnchorDelay = true
        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: coordinator.capturePostSendAnchorIntent(),
            messageCount: messages.count,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in
            unexpectedAnchor.fulfill()
        }

        await fulfillment(
            of: [visibilityEnsureCompleted, anchorDelayStarted],
            timeout: 1
        )
        coordinator.handleUserScrollInteraction()
        mayFinishAnchorDelay = true

        await fulfillment(
            of: [anchorDelayCancelled, unexpectedAnchor],
            timeout: 0.1
        )
    }

    func testUserScrollTakeoverSuppressesKeyboardAndFocusAnchorsButNotSend() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com",
            "second@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let unexpectedPassiveLatestLoad = expectation(
            description: "Keyboard and focus changes must not reload after user takeover"
        )
        unexpectedPassiveLatestLoad.isInverted = true
        var isRejectingPassiveLatestLoads = false
        var latestWindowKnownCounts: [Int?] = []
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { knownTotalCount in
                if isRejectingPassiveLatestLoads {
                    unexpectedPassiveLatestLoad.fulfill()
                } else {
                    latestWindowKnownCounts.append(knownTotalCount)
                }
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
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        latestWindowKnownCounts.removeAll()
        isRejectingPassiveLatestLoads = true
        coordinator.handleUserScrollInteraction()
        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        coordinator.handleKeyboardHeightChange(
            oldHeight: 240,
            newHeight: 0,
            messageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        coordinator.handleTextFieldFocusChange(
            isFocused: false,
            messageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await fulfillment(of: [unexpectedPassiveLatestLoad], timeout: 0.1)
        XCTAssertTrue(latestWindowKnownCounts.isEmpty)
        XCTAssertTrue(anchorSteps.isEmpty)

        isRejectingPassiveLatestLoads = false
        let anchorIntent = coordinator.capturePostSendAnchorIntent()
        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: anchorIntent,
            messageCount: messages.count,
            totalMessageCount: messages.count + 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 2
        }
        XCTAssertTrue(latestWindowKnownCounts.isEmpty)
    }

    func testReplySendCompletionAfterDisappearDoesNotRestartAnchorWork() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "first@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }
        let unexpectedPostDisappearLatestLoad = expectation(
            description: "Late send completion must not reload after disappear"
        )
        unexpectedPostDisappearLatestLoad.isInverted = true
        let unexpectedPostDisappearEnsure = expectation(
            description: "Late send completion must not publish after disappear"
        )
        unexpectedPostDisappearEnsure.isInverted = true
        var isRejectingPostDisappearLoads = false
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in
                if isRejectingPostDisappearLoads {
                    unexpectedPostDisappearLatestLoad.fulfill()
                }
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
            sleep: { _ in },
            ensureVisibleMessage: { _ in
                unexpectedPostDisappearEnsure.fulfill()
                return true
            }
        )

        coordinator.handleAppear(
            messageCount: messages.count,
            lastMessage: messages.last,
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { _ in }
        await confirmInitialBottomAnchor(coordinator)

        let anchorIntent = coordinator.capturePostSendAnchorIntent()
        isRejectingPostDisappearLoads = true
        coordinator.handleDisappear()
        coordinator.handleReplySendCompleted(
            targetMessageID: messages.last!.objectID,
            anchorIntent: anchorIntent,
            messageCount: messages.count,
            totalMessageCount: messages.count + 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }
        await fulfillment(
            of: [unexpectedPostDisappearLatestLoad, unexpectedPostDisappearEnsure],
            timeout: 0.1
        )

        XCTAssertTrue(anchorSteps.isEmpty)
    }

    func testKeyboardAndFocusChanges_requestExpectedBottomAnchors() async {
        var loadLatestWindowCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in
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
            messageCount: 0,
            lastMessage: nil,
            visibleMessages: [],
            senderGroupingMessages: [],
            totalMessageCount: 0,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("Empty appear should not schedule bottom anchoring")
        }

        XCTAssertTrue(coordinator.isReadyToShow)

        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: 2,
            isInitialWindowLoaded: true
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

        coordinator.handleKeyboardHeightChange(
            oldHeight: 240,
            newHeight: 0,
            messageCount: 2,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 4)
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
            messageCount: 2,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 6)
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

    func testKeyboardAndFocusChanges_singleMessageThreadStillAnchorsBottom() async throws {
        let (_, messages) = try makeConversationWithMessages(senderEmails: [
            "only@example.com"
        ])
        let rows = messages.map { ChatMessageRowModelMapper.map($0) }

        var loadLatestWindowCount = 0
        var anchorSteps: [ChatMessagesCoordinator.BottomAnchorStep] = []

        let coordinator = ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in
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
            visibleMessages: rows,
            senderGroupingMessages: rows,
            totalMessageCount: 1,
            isInitialWindowLoaded: true
        ) { _ in
            XCTFail("Single-message appear should not require a bottom scroll")
        }

        await confirmInitialBottomAnchor(coordinator)

        XCTAssertEqual(loadLatestWindowCount, 0)

        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: 1,
            isInitialWindowLoaded: true
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
            messageCount: 1,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        await waitUntil {
            anchorSteps.count == 1
        }

        XCTAssertEqual(loadLatestWindowCount, 4)
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
            loadLatestWindowIfNeeded: { _ in },
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
            totalMessageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        coordinator.handleKeyboardHeightChange(
            oldHeight: 0,
            newHeight: 240,
            messageCount: messages.count,
            isInitialWindowLoaded: true
        ) { step in
            anchorSteps.append(step)
        }

        XCTAssertFalse(coordinator.isReadyToShow)
        XCTAssertTrue(anchorSteps.isEmpty)

        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: false
        ) { step in
            anchorSteps.append(step)
        }
        await confirmInitialBottomAnchor(coordinator)
        XCTAssertTrue(coordinator.isReadyToShow)
        XCTAssertEqual(
            anchorSteps,
            [
                .init(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView initial layout scroll -> bottom anchor"
                )
            ]
        )

        let animatedScrollCount = anchorSteps.filter {
            $0.logMessage == "ChatView animated scroll -> bottom anchor"
        }.count

        coordinator.handleMessageCountChange(
            oldCount: messages.count,
            newCount: messages.count + 1,
            lastMessage: messages.last,
            visibleMessages: rows,
            totalMessageCount: messages.count,
            stabilizeBottomAnchor: true,
            isInitialWindowLoaded: true,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: true
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
            loadLatestWindowIfNeeded: { _ in },
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

    private func makeUnreadCoordinator(
        markConversationAsReadIfNeeded: @escaping () -> Void,
        markUnreadInboxMessagesAsReadIfNeeded: @escaping ([NSManagedObjectID]) -> Void,
        sleep: @escaping ChatMessagesCoordinator.Sleep = { _ in },
        now: @escaping ChatMessagesCoordinator.Now = {
            ProcessInfo.processInfo.systemUptime
        },
        ensureVisibleMessage: @escaping ChatMessagesCoordinator.MessageVisibilityEnsurer = {
            _ in true
        }
    ) -> ChatMessagesCoordinator {
        ChatMessagesCoordinator(
            loadLatestWindowIfNeeded: { _ in },
            markConversationAsReadIfNeeded: markConversationAsReadIfNeeded,
            markUnreadInboxMessagesAsReadIfNeeded: markUnreadInboxMessagesAsReadIfNeeded,
            initializeReplyingTo: { _ in },
            updateReplyingToIfNewSubject: { _ in },
            loadResolvedDisplayName: {},
            prefetchRecentContent: { _, _ in },
            cancelPrefetch: {},
            loadSenderGroupingKeys: { _ in [:] },
            invalidateContactsCache: {},
            clearPersonCache: {},
            sleep: sleep,
            now: now,
            ensureVisibleMessage: ensureVisibleMessage
        )
    }

    private func makeMessageObjectID(_ id: String) -> NSManagedObjectID {
        MessageBuilder()
            .withId(id)
            .build(in: viewContext)
            .objectID
    }

    private func handleEmptyAppear(_ coordinator: ChatMessagesCoordinator) {
        coordinator.handleAppear(
            messageCount: 0,
            lastMessage: nil,
            visibleMessages: [],
            senderGroupingMessages: [],
            totalMessageCount: 0,
            isInitialWindowLoaded: true
        ) { _ in }
    }

    private func handleRefreshAndLayout(
        _ coordinator: ChatMessagesCoordinator,
        event: VirtualScrollInsertedMessageEvent,
        messageIDsInLatestWindow: [NSManagedObjectID],
        isChatActiveAtRefresh: Bool = true,
        isChatActiveAtLayout: Bool = true,
        isBottomAnchorVisible: Bool = true
    ) {
        let layoutID = UUID()
        coordinator.handleRefreshedInsertedMessageEvent(
            .init(
                eventID: event.id,
                layoutID: layoutID,
                messageIDsInLatestWindow: messageIDsInLatestWindow
            ),
            isChatActiveAndUncovered: isChatActiveAtRefresh,
            isShowingLatestWindow: true
        )
        coordinator.handleLatestWindowLayout(
            layoutID: layoutID,
            isChatActiveAndUncovered: isChatActiveAtLayout,
            isShowingLatestWindow: true,
            isBottomAnchorVisible: isBottomAnchorVisible
        )
    }

    private func confirmInitialBottomAnchor(
        _ coordinator: ChatMessagesCoordinator,
        contentMinY: CGFloat = 0,
        contentHeight: CGFloat = 100,
        viewportHeight: CGFloat = 100,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let geometryCheckBeforeConfirmation = coordinator.initialAnchorGeometryCheckID
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            contentMinY: contentMinY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        ) { _ in
            XCTFail(
                "A visible initial anchor should not request a scroll",
                file: file,
                line: line
            )
        }
        await waitUntil(file: file, line: line) {
            coordinator.initialAnchorGeometryCheckID != geometryCheckBeforeConfirmation
        }
        XCTAssertFalse(coordinator.isReadyToShow, file: file, line: line)
        coordinator.handleBottomAnchorGeometryUpdate(
            isBottomAnchorVisible: true,
            contentMinY: contentMinY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        ) { _ in
            XCTFail(
                "A stable visible initial anchor should not request a scroll",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(coordinator.isReadyToShow, file: file, line: line)
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
