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
    let contactsResolver: any ContactsResolving
    let htmlContentHandler: HTMLContentHandler
    let participantLoader: ParticipantLoader
    let conversationManager: ConversationManager

    // MARK: - Actor-based Services
    // Actors stored as let properties for injection, accessed via nonisolated getters

    private let _attachmentCache: AttachmentCacheActor
    private let _pendingActionsManager: PendingActionsManager
    private let _processedTextCache: ProcessedTextCache
    private let _profilePhotoResolver: ProfilePhotoResolver
    private let _htmlContentRecoveryService: HTMLContentRecoveryService

    /// Returns the AttachmentCacheActor instance.
    /// Use `await` when calling methods on this actor.
    nonisolated var attachmentCache: AttachmentCacheActor {
        _attachmentCache
    }

    /// Returns the PendingActionsManager actor instance.
    /// Use `await` when calling methods on this actor.
    nonisolated var pendingActionsManager: PendingActionsManager {
        _pendingActionsManager
    }

    nonisolated var processedTextCache: ProcessedTextCache {
        _processedTextCache
    }

    nonisolated var profilePhotoResolver: ProfilePhotoResolver {
        _profilePhotoResolver
    }

    nonisolated var htmlContentRecoveryService: HTMLContentRecoveryService {
        _htmlContentRecoveryService
    }

    // MARK: - Service Layer

    let syncEngine: SyncEngine
    let foregroundSyncCoordinator: ForegroundSyncCoordinator
    let attachmentDownloader: AttachmentDownloader
    let backgroundSyncManager: BackgroundSyncManager

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

    func makeConversationSearchService() -> ConversationSearchService {
        ConversationSearchService()
    }

    func makeConversationSelectionService() -> ConversationSelectionService {
        ConversationSelectionService(
            messageActions: makeMessageActions(),
            coreDataStack: coreDataStack
        )
    }

    func makeConversationFilterService() -> ConversationFilterService {
        ConversationFilterService(contactsService: makeContactsService())
    }

    func makeChatContactManager() -> ChatContactManager {
        ChatContactManager()
    }

    func makeRecipientManager() -> RecipientManager {
        RecipientManager(authSession: authSession)
    }

    func makeContactAutocompleteService() -> ContactAutocompleteService {
        ContactAutocompleteService()
    }

    func makeComposeAttachmentManager() -> ComposeAttachmentManager {
        ComposeAttachmentManager(viewContext: viewContext)
    }

    func makeReplyMetadataBuilder() -> ReplyMetadataBuilder {
        ReplyMetadataBuilder(authSession: authSession)
    }

    func makeMessageFormatBuilder() -> MessageFormatBuilder {
        MessageFormatBuilder(authSession: authSession)
    }

    func makeMessageBubbleLoader() -> MessageBubbleLoader {
        MessageBubbleLoader(
            contactsResolver: contactsResolver,
            processedTextCache: processedTextCache,
            htmlContentHandler: htmlContentHandler,
            htmlContentRecoveryService: htmlContentRecoveryService
        )
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
        self.contactsResolver = ContactsResolver.shared
        self.htmlContentHandler = HTMLContentHandler.shared
        self._attachmentCache = AttachmentCacheActor.shared
        self._pendingActionsManager = PendingActionsManager.shared
        self._processedTextCache = ProcessedTextCache.shared
        self._profilePhotoResolver = ProfilePhotoResolver.shared
        self._htmlContentRecoveryService = HTMLContentRecoveryService.shared
        self.syncEngine = SyncEngine.shared
        self.foregroundSyncCoordinator = ForegroundSyncCoordinator.shared
        self.attachmentDownloader = AttachmentDownloader.shared
        self.backgroundSyncManager = BackgroundSyncManager.shared
        self.participantLoader = ParticipantLoader(
            personCache: self.personCache,
            photoResolver: self._profilePhotoResolver
        )
        self.conversationManager = ConversationManager(
            rollupUpdater: ConversationRollupUpdater(coreDataStack: self.coreDataStack),
            merger: ConversationMerger(coreDataStack: self.coreDataStack),
            currentUserEmail: { [authSession] in
                authSession.userEmail ?? ""
            }
        )
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
        contactsResolver: (any ContactsResolving)? = nil,
        attachmentCache: AttachmentCacheActor,
        pendingActionsManager: PendingActionsManager,
        processedTextCache: ProcessedTextCache = .shared,
        profilePhotoResolver: ProfilePhotoResolver = .shared,
        htmlContentHandler: HTMLContentHandler = .shared,
        htmlContentRecoveryService: HTMLContentRecoveryService = .shared,
        syncEngine: SyncEngine,
        foregroundSyncCoordinator: ForegroundSyncCoordinator,
        attachmentDownloader: AttachmentDownloader,
        backgroundSyncManager: BackgroundSyncManager,
        participantLoader: ParticipantLoader? = nil,
        conversationManager: ConversationManager? = nil
    ) {
        self.coreDataStack = coreDataStack
        self.keychainService = keychainService
        self.authSession = authSession
        self.tokenManager = tokenManager
        self.gmailAPIClient = gmailAPIClient
        self.personCache = personCache
        self.conversationCache = conversationCache
        self.contactsResolver = contactsResolver ?? ContactsResolver.shared
        self.htmlContentHandler = htmlContentHandler
        self._attachmentCache = attachmentCache
        self._pendingActionsManager = pendingActionsManager
        self._processedTextCache = processedTextCache
        self._profilePhotoResolver = profilePhotoResolver
        self._htmlContentRecoveryService = htmlContentRecoveryService
        self.syncEngine = syncEngine
        self.foregroundSyncCoordinator = foregroundSyncCoordinator
        self.attachmentDownloader = attachmentDownloader
        self.backgroundSyncManager = backgroundSyncManager
        self.participantLoader = participantLoader ?? ParticipantLoader(
            personCache: personCache,
            photoResolver: profilePhotoResolver
        )
        self.conversationManager = conversationManager ?? ConversationManager(
            rollupUpdater: ConversationRollupUpdater(coreDataStack: coreDataStack),
            merger: ConversationMerger(coreDataStack: coreDataStack),
            currentUserEmail: { [authSession] in
                authSession.userEmail ?? ""
            }
        )
    }
}
