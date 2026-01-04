import Foundation
import CoreData

/// Lightweight dependency container for the application.
///
/// This container centralizes access to all app services, enabling:
/// - Dependency injection for testing (pass mock implementations)
/// - Cleaner code without scattered `.shared` singleton access
/// - Explicit dependency graphs
///
/// Usage in SwiftUI views:
/// ```swift
/// @EnvironmentObject private var deps: Dependencies
/// ```
///
/// Usage in ViewModels/Services:
/// ```swift
/// init(deps: Dependencies = .shared) {
///     self.coreDataStack = deps.coreDataStack
/// }
/// ```
@MainActor
final class Dependencies: ObservableObject {

    // MARK: - Shared Instance

    /// Production singleton that uses all default `.shared` services
    static let shared = Dependencies()

    // MARK: - Foundational Layer (no dependencies on other services)

    let coreDataStack: CoreDataStack
    let keychainService: KeychainServiceProtocol

    // MARK: - Security Layer

    let authSession: AuthSession
    let tokenManager: TokenManagerProtocol

    // MARK: - API Layer

    let gmailAPIClient: GmailAPIClient

    // MARK: - Cache Layer

    let personCache: PersonCache
    let conversationCache: ConversationCache

    /// Returns the shared AttachmentCacheActor instance.
    /// Use `await` when calling methods on this actor.
    nonisolated var attachmentCache: AttachmentCacheActor {
        AttachmentCacheActor.shared
    }

    // MARK: - Service Layer

    let syncEngine: SyncEngine
    let attachmentDownloader: AttachmentDownloader
    let backgroundSyncManager: BackgroundSyncManager

    // MARK: - Actor-based Services
    // Actors are accessed via computed property to maintain actor isolation

    /// Returns the shared PendingActionsManager actor instance.
    /// Use `await` when calling methods on this actor.
    nonisolated var pendingActionsManager: PendingActionsManager {
        PendingActionsManager.shared
    }

    // MARK: - Convenience Accessors

    /// Main thread Core Data context for UI operations
    var viewContext: NSManagedObjectContext {
        coreDataStack.viewContext
    }

    /// Creates a new background context for heavy operations
    func newBackgroundContext() -> NSManagedObjectContext {
        coreDataStack.newBackgroundContext()
    }

    // MARK: - Service Factories

    /// Creates a new MessageActions instance with injected dependencies
    func makeMessageActions() -> MessageActions {
        MessageActions(
            coreDataStack: coreDataStack,
            pendingActionsManager: pendingActionsManager
        )
    }

    /// Creates a new GmailSendService instance with injected dependencies
    func makeSendService() -> GmailSendService {
        GmailSendService(
            viewContext: viewContext,
            apiClient: gmailAPIClient,
            authSession: authSession
        )
    }

    /// Creates a new ContactsService instance
    func makeContactsService() -> ContactsService {
        ContactsService()
    }

    // MARK: - Initialization

    /// Production initializer - uses all shared singleton instances.
    /// This is the default used by `.shared` and production code.
    init() {
        self.coreDataStack = CoreDataStack.shared
        self.keychainService = KeychainService.shared
        self.authSession = AuthSession.shared
        self.tokenManager = TokenManager.shared
        self.gmailAPIClient = GmailAPIClient.shared
        self.personCache = PersonCache.shared
        self.conversationCache = ConversationCache.shared
        self.syncEngine = SyncEngine.shared
        self.attachmentDownloader = AttachmentDownloader.shared
        self.backgroundSyncManager = BackgroundSyncManager.shared
    }

    /// Testing initializer - accepts custom implementations for all dependencies.
    ///
    /// Use this in unit tests to inject mock implementations:
    /// ```swift
    /// let mockCoreData = MockCoreDataStack()
    /// let deps = Dependencies(
    ///     coreDataStack: mockCoreData,
    ///     keychainService: MockKeychainService(),
    ///     // ... other mocks
    /// )
    /// let viewModel = ChatViewModel(deps: deps)
    /// ```
    init(
        coreDataStack: CoreDataStack,
        keychainService: KeychainServiceProtocol,
        authSession: AuthSession,
        tokenManager: TokenManagerProtocol,
        gmailAPIClient: GmailAPIClient,
        personCache: PersonCache,
        conversationCache: ConversationCache,
        syncEngine: SyncEngine,
        attachmentDownloader: AttachmentDownloader,
        backgroundSyncManager: BackgroundSyncManager
    ) {
        self.coreDataStack = coreDataStack
        self.keychainService = keychainService
        self.authSession = authSession
        self.tokenManager = tokenManager
        self.gmailAPIClient = gmailAPIClient
        self.personCache = personCache
        self.conversationCache = conversationCache
        self.syncEngine = syncEngine
        self.attachmentDownloader = attachmentDownloader
        self.backgroundSyncManager = backgroundSyncManager
    }
}
