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
    let outboundSendMutationTracker: any OutboundSendMutationTracking
    private let outboundMessageCoordinatorOverride: (any OutboundMessageCoordinating)?

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

    func makeOutboundMessageCoordinator() -> any OutboundMessageCoordinating {
        if let outboundMessageCoordinatorOverride {
            return outboundMessageCoordinatorOverride
        }

        return OutboundMessageCoordinator(
            sendService: makeSendService(),
            syncPerformer: syncEngine,
            messageFormatBuilder: makeMessageFormatBuilder(),
            mutationTracker: outboundSendMutationTracker
        )
    }

    func makeOutboundReplyContextBuilder() -> OutboundReplyContextBuilder {
        OutboundReplyContextBuilder(replyMetadataBuilder: makeReplyMetadataBuilder())
    }

    func makeComposeReplyModeContextBuilder() -> ComposeReplyModeContextBuilder {
        ComposeReplyModeContextBuilder(
            outboundReplyContextBuilder: makeOutboundReplyContextBuilder()
        )
    }

    func makeComposeForwardModeContextBuilder() -> ComposeForwardModeContextBuilder {
        ComposeForwardModeContextBuilder(
            messageFormatBuilder: makeMessageFormatBuilder(),
            outboundAttachmentContextBuilder: makeOutboundAttachmentContextBuilder()
        )
    }

    func makeOutboundAttachmentContextBuilder() -> OutboundAttachmentContextBuilder {
        OutboundAttachmentContextBuilder(viewContext: viewContext)
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
        RecipientManager()
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
    convenience init() {
        self.init(
            coreDataStack: CoreDataStack.shared,
            keychainService: KeychainService.shared
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
        coreDataStack: CoreDataStack = CoreDataStack.shared,
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        authSession: AuthSession? = nil,
        tokenManager: TokenManagerProtocol? = nil,
        gmailAPIClient: GmailAPIClient? = nil,
        personCache: PersonCache = PersonCache.shared,
        conversationCache: ConversationCache? = nil,
        contactsResolver: (any ContactsResolving)? = nil,
        attachmentCache: AttachmentCacheActor = AttachmentCacheActor.shared,
        pendingActionsManager: PendingActionsManager = PendingActionsManager.shared,
        processedTextCache: ProcessedTextCache = .shared,
        profilePhotoResolver: ProfilePhotoResolver = .shared,
        htmlContentHandler: HTMLContentHandler = .shared,
        htmlContentRecoveryService: HTMLContentRecoveryService = .shared,
        syncEngine: SyncEngine? = nil,
        foregroundSyncCoordinator: ForegroundSyncCoordinator? = nil,
        attachmentDownloader: AttachmentDownloader? = nil,
        backgroundSyncManager: BackgroundSyncManager = BackgroundSyncManager.shared,
        participantLoader: ParticipantLoader? = nil,
        conversationManager: ConversationManager? = nil,
        outboundSendMutationTracker: (any OutboundSendMutationTracking)? = nil,
        outboundMessageCoordinator: (any OutboundMessageCoordinating)? = nil
    ) {
        let resolvedAuthSession = authSession ?? AuthSession.shared
        let resolvedTokenManager = tokenManager ?? TokenManager.shared
        let resolvedGmailAPIClient = gmailAPIClient ?? GmailAPIClient.shared
        let resolvedConversationCache = conversationCache ?? ConversationCache.shared
        let resolvedContactsResolver = contactsResolver ?? ContactsResolver.shared
        let resolvedSyncEngine = syncEngine ?? SyncEngine.shared
        let resolvedForegroundSyncCoordinator = foregroundSyncCoordinator ?? ForegroundSyncCoordinator.shared
        let resolvedAttachmentDownloader = attachmentDownloader ?? AttachmentDownloader.shared

        self.coreDataStack = coreDataStack
        self.keychainService = keychainService
        self.authSession = resolvedAuthSession
        self.tokenManager = resolvedTokenManager
        self.gmailAPIClient = resolvedGmailAPIClient
        self.personCache = personCache
        self.conversationCache = resolvedConversationCache
        self.contactsResolver = resolvedContactsResolver
        self.htmlContentHandler = htmlContentHandler
        self._attachmentCache = attachmentCache
        self._pendingActionsManager = pendingActionsManager
        self._processedTextCache = processedTextCache
        self._profilePhotoResolver = profilePhotoResolver
        self._htmlContentRecoveryService = htmlContentRecoveryService
        self.syncEngine = resolvedSyncEngine
        self.foregroundSyncCoordinator = resolvedForegroundSyncCoordinator
        self.attachmentDownloader = resolvedAttachmentDownloader
        self.backgroundSyncManager = backgroundSyncManager
        self.outboundSendMutationTracker = outboundSendMutationTracker ?? OutboundSendMutationTracker()
        self.outboundMessageCoordinatorOverride = outboundMessageCoordinator
        self.participantLoader = participantLoader ?? ParticipantLoader(
            personCache: personCache,
            photoResolver: profilePhotoResolver
        )
        self.conversationManager = conversationManager ?? ConversationManager(
            rollupUpdater: ConversationRollupUpdater(coreDataStack: coreDataStack),
            merger: ConversationMerger(coreDataStack: coreDataStack),
            currentUserEmail: { [resolvedAuthSession] in
                resolvedAuthSession.userEmail ?? ""
            }
        )
    }
}
