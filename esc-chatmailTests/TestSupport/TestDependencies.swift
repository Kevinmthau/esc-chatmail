import Foundation
import CoreData
@testable import esc_chatmail

/// Test-focused dependencies container that uses mocks and in-memory storage.
/// Provides easy access to mock implementations for verification in tests.
@MainActor
final class TestDependencies {

    // MARK: - Test Infrastructure

    let coreDataStack: TestCoreDataStack
    let mockKeychain: MockKeychainService
    let mockTokenManager: MockTokenManager

    // MARK: - Computed Properties

    var viewContext: NSManagedObjectContext {
        coreDataStack.viewContext
    }

    // MARK: - Initialization

    init() {
        self.coreDataStack = TestCoreDataStack()
        self.mockKeychain = MockKeychainService()
        self.mockTokenManager = MockTokenManager()
    }

    // MARK: - Reset

    /// Resets all mocks to their initial state.
    /// Call this in tearDown() to ensure clean state between tests.
    func resetAll() {
        coreDataStack.resetViewContext()
        mockKeychain.reset()
        mockTokenManager.reset()
    }

    // MARK: - Helpers

    /// Creates a new background context for testing
    func newBackgroundContext() -> NSManagedObjectContext {
        coreDataStack.newBackgroundContext()
    }

    /// Saves the view context
    func saveViewContext() throws {
        try coreDataStack.saveViewContext()
    }

    /// Performs a background task and saves
    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await coreDataStack.performBackgroundTask(block)
    }
}

// MARK: - Builder Factory Extensions

extension TestDependencies {
    /// Creates a MessageBuilder for this test context
    func messageBuilder() -> MessageBuilder {
        MessageBuilder()
    }

    /// Creates a ConversationBuilder for this test context
    func conversationBuilder() -> ConversationBuilder {
        ConversationBuilder()
    }

    /// Creates a PendingActionBuilder for this test context
    func pendingActionBuilder() -> PendingActionBuilder {
        PendingActionBuilder()
    }
}

// MARK: - Convenience Factory Methods

extension TestDependencies {
    /// Creates a simple message in the view context
    func createMessage(
        id: String = UUID().uuidString,
        subject: String = "Test Subject",
        senderEmail: String = "sender@example.com"
    ) -> Message {
        MessageBuilder()
            .withId(id)
            .withSubject(subject)
            .withSender(email: senderEmail)
            .build(in: viewContext)
    }

    /// Creates a simple conversation in the view context
    func createConversation(
        displayName: String = "Test Conversation"
    ) -> Conversation {
        ConversationBuilder()
            .withDisplayName(displayName)
            .visible()
            .recentlyActive()
            .build(in: viewContext)
    }

    /// Creates a pending action in the view context
    func createPendingAction(
        type: String = "markRead",
        messageId: String = "test-message"
    ) -> PendingAction {
        PendingActionBuilder()
            .withActionType(type)
            .forMessage(messageId)
            .pending()
            .build(in: viewContext)
    }
}
