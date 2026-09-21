import CoreData
import XCTest
@testable import esc_chatmail

/// Models the interval between maintenance's protected-draft snapshot and its
/// conversation deletion. The real cleanup implementation is covered by its
/// own suites; these tests pin the composer's participation in the same gate.
@MainActor
final class ChatReplyDraftCleanupSerializationTests: XCTestCase {
    func testFirstDraftSaveWaitsUntilCleanupSnapshotFinishes() async throws {
        let serializer = ConversationRollupMutationSerializer()
        let fixture = try makeFixture(serializer: serializer)
        let context = fixture.context
        let cleanupContext = fixture.stack.newBackgroundContext()
        let snapshotCaptured = DraftCleanupTestGate()
        let finishCleanup = DraftCleanupTestGate()
        let draftSaveEnqueued = DraftCleanupTestGate()
        defer { Task { await finishCleanup.open() } }

        let cleanup = Task {
            try await serializer.performThrowingCleanupSensitiveMutation {
                let protectedIDs = try await cleanupContext.perform {
                    let request = NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
                    return Set(try cleanupContext.fetch(request).map(\.conversationId))
                }
                await snapshotCaptured.open()
                await finishCleanup.wait()
                return protectedIDs
            }
        }
        await snapshotCaptured.wait()

        fixture.viewModel.replyText = "First draft written during cleanup"
        let save = Task {
            await fixture.viewModel.saveReplyDraft(onEnqueued: {
                await draftSaveEnqueued.open()
            })
        }
        await draftSaveEnqueued.wait()

        // Enqueue acknowledgment proves save has joined the serializer behind
        // cleanup. No sleep or scheduling assumption is needed to inspect it.
        XCTAssertEqual(try context.count(for: draftRequest()), 0)
        XCTAssertEqual(fixture.viewModel.replyText, "First draft written during cleanup")

        await finishCleanup.open()
        let protectedIDs = try await cleanup.value
        await save.value

        XCTAssertTrue(protectedIDs.isEmpty)
        let stored = try XCTUnwrap(ChatReplyDraftStore(context: context).load(conversationID: fixture.conversationID))
        XCTAssertEqual(stored.0.text, "First draft written during cleanup")
        XCTAssertEqual(try context.count(for: draftRequest()), 1)
        XCTAssertNil(fixture.viewModel.sendErrorAlert)
    }

    func testCleanupDeletingAnchorBeforeQueuedSaveKeepsComposerAndRejectsOrphanDraft() async throws {
        let serializer = ConversationRollupMutationSerializer()
        let fixture = try makeFixture(serializer: serializer)
        let context = fixture.context
        let cleanupContext = fixture.stack.newBackgroundContext()
        let conversationObjectID = fixture.conversationObjectID
        let conversationID = fixture.conversationID
        let snapshotCaptured = DraftCleanupTestGate()
        let finishCleanup = DraftCleanupTestGate()
        let draftSaveEnqueued = DraftCleanupTestGate()
        defer { Task { await finishCleanup.open() } }

        let cleanup = Task {
            try await serializer.performThrowingCleanupSensitiveMutation {
                let protectedIDs = try await cleanupContext.perform {
                    let request = NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
                    return Set(try cleanupContext.fetch(request).map(\.conversationId))
                }
                await snapshotCaptured.open()
                await finishCleanup.wait()
                try await cleanupContext.perform {
                    guard !protectedIDs.contains(conversationID) else { return }
                    let conversation = try cleanupContext.existingObject(with: conversationObjectID)
                    cleanupContext.delete(conversation)
                    try cleanupContext.save()
                }
            }
        }
        await snapshotCaptured.wait()

        fixture.viewModel.replyText = "Keep this reply even if its anchor is deleted"
        let save = Task {
            await fixture.viewModel.saveReplyDraft(onEnqueued: {
                await draftSaveEnqueued.open()
            })
        }
        await draftSaveEnqueued.wait()
        XCTAssertEqual(try context.count(for: draftRequest()), 0)

        await finishCleanup.open()
        try await cleanup.value
        await save.value

        XCTAssertEqual(fixture.viewModel.replyText, "Keep this reply even if its anchor is deleted")
        XCTAssertEqual(fixture.viewModel.sendErrorAlert?.title, "Couldn’t Save Draft")
        XCTAssertEqual(try context.count(for: draftRequest()), 0)
        let durableDraftCount = try await cleanupContext.perform {
            try cleanupContext.count(for: NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft"))
        }
        XCTAssertEqual(durableDraftCount, 0)
    }

    func testQueuedSaveDoesNotRecreateDraftDiscardedWhileCleanupIsRunning() async throws {
        let serializer = ConversationRollupMutationSerializer()
        let fixture = try makeFixture(serializer: serializer)
        let cleanupStarted = DraftCleanupTestGate()
        let finishCleanup = DraftCleanupTestGate()
        let draftSaveEnqueued = DraftCleanupTestGate()
        defer { Task { await finishCleanup.open() } }

        let cleanup = Task {
            await serializer.performCleanupSensitiveMutation {
                await cleanupStarted.open()
                await finishCleanup.wait()
            }
        }
        await cleanupStarted.wait()
        fixture.viewModel.replyText = "Discard this queued draft"
        let save = Task {
            await fixture.viewModel.saveReplyDraft(onEnqueued: {
                await draftSaveEnqueued.open()
            })
        }
        await draftSaveEnqueued.wait()
        fixture.viewModel.discardReplyDraft()

        await finishCleanup.open()
        await cleanup.value
        await save.value

        XCTAssertTrue(fixture.viewModel.replyText.isEmpty)
        XCTAssertEqual(try fixture.context.count(for: draftRequest()), 0)
        XCTAssertNil(fixture.viewModel.sendErrorAlert)
    }

    private func draftRequest() -> NSFetchRequest<ChatReplyDraft> {
        NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
    }

    private func makeFixture(serializer: ConversationRollupMutationSerializer) throws -> (
        stack: TestCoreDataStack,
        dependencies: Dependencies,
        context: NSManagedObjectContext,
        conversationID: UUID,
        conversationObjectID: NSManagedObjectID,
        viewModel: ChatViewModel
    ) {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let tokenManager = MockTokenManager()
        let auth = AuthSession(
            tokenManagerProvider: { tokenManager },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ChatReplyDraftCleanupSerializationTests.\(UUID().uuidString)")!,
            clearConversationCaches: {}, cleanupDownloads: {}, resetCoreDataStore: {}, clearAttachmentCache: {}
        )
        auth.userEmail = "me@example.com"
        let dependencies = Dependencies(
            authSession: auth, tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
        let base = dependencies.makeChatDependencies()
        let chatDependencies = ChatDependencies(
            session: base.session, content: base.content, messaging: base.messaging, contacts: base.contacts,
            storage: ChatStorageDependencies(viewContext: context, makeBackgroundContext: { stack.newBackgroundContext() }),
            fullEmailOpener: base.fullEmailOpener
        )
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: context)
        _ = MessageBuilder().withId(UUID().uuidString).inConversation(conversation).build(in: context)
        try context.save()
        let viewModel = ChatViewModel(
            conversation: conversation, chatDependencies: chatDependencies,
            conversationMutationSerializer: serializer
        )
        return (stack, dependencies, context, conversation.id, conversation.objectID, viewModel)
    }
}

private actor DraftCleanupTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
