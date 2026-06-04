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
/// Usage in feature wiring:
/// ```swift
/// let composeDependencies = deps.makeComposeDependencies()
/// let viewModel = ComposeViewModel(mode: .newMessage, dependencies: composeDependencies)
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
            outboundReplyContextBuilder: makeOutboundReplyContextBuilder(),
            mutationTracker: outboundSendMutationTracker
        )
    }

    func makeOutboundReplyContextBuilder() -> OutboundReplyContextBuilder {
        OutboundReplyContextBuilder(
            viewContext: viewContext,
            replyMetadataBuilder: makeReplyMetadataBuilder(),
            replyHTMLContentLoader: HTMLContentLoader(
                contentHandler: htmlContentHandler,
                sanitizer: .shared
            )
        )
    }

    func makeComposeReplyModeContextBuilder() -> ComposeReplyModeContextBuilder {
        ComposeReplyModeContextBuilder(
            outboundReplyContextBuilder: makeOutboundReplyContextBuilder()
        )
    }

    func makeComposeForwardModeContextBuilder() -> ComposeForwardModeContextBuilder {
        ComposeForwardModeContextBuilder(
            messageFormatBuilder: makeMessageFormatBuilder()
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

    func makeStorageDependencies() -> StorageDependencies {
        StorageDependencies(
            viewContext: viewContext,
            makeBackgroundContext: { [coreDataStack] in
                coreDataStack.newBackgroundContext()
            },
            saveIfNeeded: { [coreDataStack] context in
                coreDataStack.saveIfNeeded(context: context)
            },
            personCache: personCache,
            profilePhotoResolver: profilePhotoResolver
        )
    }

    func makeMessagingDependencies() -> MessagingDependencies {
        MessagingDependencies(
            makeMessageActions: { [self] in
                makeMessageActions()
            },
            makeOutboundMessageCoordinator: { [self] in
                makeOutboundMessageCoordinator()
            },
            makeOutboundReplyContextBuilder: { [self] in
                makeOutboundReplyContextBuilder()
            },
            makeComposeReplyModeContextBuilder: { [self] in
                makeComposeReplyModeContextBuilder()
            },
            makeComposeForwardModeContextBuilder: { [self] in
                makeComposeForwardModeContextBuilder()
            },
            makeOutboundAttachmentContextBuilder: { [self] in
                makeOutboundAttachmentContextBuilder()
            }
        )
    }

    func makeComposeDependencies() -> ComposeDependencies {
        ComposeDependencies(
            storage: makeStorageDependencies(),
            messaging: makeMessagingDependencies(),
            makeRecipientManager: { [self] in
                makeRecipientManager()
            },
            makeContactAutocompleteService: { [self] in
                makeContactAutocompleteService()
            },
            makeComposeAttachmentManager: { [self] in
                makeComposeAttachmentManager()
            }
        )
    }

    func makeConversationListDependencies() -> ConversationListDependencies {
        ConversationListDependencies(
            storage: makeStorageDependencies(),
            messaging: makeMessagingDependencies(),
            syncEngine: syncEngine,
            foregroundSyncCoordinator: foregroundSyncCoordinator,
            conversationManager: conversationManager,
            makeConversationSearchService: { [self] in
                makeConversationSearchService()
            },
            makeConversationSelectionService: { [self] in
                makeConversationSelectionService()
            },
            makeConversationFilterService: { [self] in
                makeConversationFilterService()
            }
        )
    }

    func makeChatDependencies(
        fullEmailOpener: (any FullEmailOpening)? = nil
    ) -> ChatDependencies {
        let contactsResolver = self.contactsResolver
        let personCache = self.personCache
        let processedTextCache = self.processedTextCache
        let htmlContentHandler = self.htmlContentHandler
        let htmlContentRecoveryService = self.htmlContentRecoveryService
        let makeMessageBubbleLoader = {
            MessageBubbleLoader(
                contactsResolver: contactsResolver,
                processedTextCache: processedTextCache,
                htmlContentHandler: htmlContentHandler,
                htmlContentRecoveryService: htmlContentRecoveryService
            )
        }

        return ChatDependencies(
            session: ChatSessionDependencies(
                authSession: authSession
            ),
            content: ChatContentDependencies(
                htmlContentHandler: htmlContentHandler,
                processedTextCache: processedTextCache,
                makeMessageBubbleLoader: makeMessageBubbleLoader
            ),
            messaging: ChatMessagingDependencies(
                messageActions: makeMessageActions(),
                outboundMessageCoordinator: makeOutboundMessageCoordinator(),
                outboundAttachmentContextBuilder: makeOutboundAttachmentContextBuilder(),
                outboundReplyContextBuilder: makeOutboundReplyContextBuilder(),
                composeForwardModeContextBuilder: makeComposeForwardModeContextBuilder()
            ),
            contacts: ChatContactDependencies(
                participantLoader: participantLoader,
                contactsResolver: contactsResolver,
                makeChatContactManager: { ChatContactManager() },
                invalidateContactsCache: {
                    if let contactsResolver = contactsResolver as? ContactsResolver {
                        await contactsResolver.invalidateAllCache()
                    }
                },
                clearPersonCache: {
                    await personCache.clearCache()
                }
            ),
            storage: ChatStorageDependencies(
                viewContext: viewContext,
                makeBackgroundContext: { [coreDataStack] in
                    coreDataStack.newBackgroundContext()
                }
            ),
            fullEmailOpener: fullEmailOpener ?? FullEmailWebViewManager.shared
        )
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
    /// let composeDependencies = deps.makeComposeDependencies()
    /// let viewModel = ComposeViewModel(dependencies: composeDependencies)
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
