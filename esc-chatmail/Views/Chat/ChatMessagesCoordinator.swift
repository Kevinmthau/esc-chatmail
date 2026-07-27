import Foundation
import CoreData
import CoreGraphics
import Combine

@MainActor
final class ChatMessagesCoordinator: ObservableObject {
    enum InitialPresentationAnchor: Equatable {
        case top
        case bottom
    }

    private enum TaskKey {
        static let bottomAnchor = "bottomAnchor"
        static let initialBottomAnchor = "initialBottomAnchor"
        static let initialGeometryCheck = "initialGeometryCheck"
        static let latestWindow = "latestWindow"
        static let postRevealGeometryCheck = "postRevealGeometryCheck"
        static let scrollTakeoverRelease = "scrollTakeoverRelease"
    }

    private enum InitialRevealState: Equatable {
        case waitingForRows
        case pending(scrollAttempts: Int, phase: InitialRevealPhase)
        case ready(wasEmptyConversation: Bool)
    }

    private enum InitialRevealPhase: Equatable {
        case awaitingGeometry
        case checkingAfterScroll
        case confirmingVisibility
        case validatingVisibility
    }

    private enum PostRevealBottomFollowState {
        case inactive
        case following(deadline: TimeInterval)
        case checkingAfterScroll(deadline: TimeInterval, scrollAttempts: Int)
        case waitingForGrowth(deadline: TimeInterval)
    }

    private static let maximumInitialScrollAttempts = 2
    private static let maximumPostRevealScrollAttempts = 2
    private static let postRevealBottomFollowGracePeriod: TimeInterval = 3.0
    private static let geometryChangeTolerance: CGFloat = 0.5

    struct BottomAnchorStep: Equatable {
        let delay: TimeInterval
        let animated: Bool
        let logMessage: String
    }

    typealias BottomAnchorAction = @MainActor (BottomAnchorStep) -> Void
    typealias SenderGroupingLoader = ([String]) async -> [String: String]
    typealias AsyncAction = () async -> Void
    typealias LatestWindowLoader = (Int?) async -> Void
    typealias Sleep = (UInt64) async -> Void
    typealias Now = () -> TimeInterval

    @Published private(set) var isReadyToShow = false
    @Published private(set) var contactRefreshToken = 0
    @Published private(set) var senderGroupingKeysByEmail: [String: String] = [:]
    @Published private(set) var initialAnchorGeometryCheckID = UUID()
    @Published private(set) var isUserScrollTakeoverActive = false

    private let loadLatestWindowIfNeeded: LatestWindowLoader
    private let markConversationAsReadIfNeeded: () -> Void
    private let markUnreadInboxMessagesAsReadIfNeeded: ([NSManagedObjectID]) -> Void
    private let initializeReplyingTo: (Message?) -> Void
    private let updateReplyingToIfNewSubject: (Message?) -> Void
    private let loadResolvedDisplayName: () -> Void
    private let prefetchRecentContent: ([String], [String]) -> Void
    private let cancelPrefetch: () -> Void
    private let loadSenderGroupingKeys: SenderGroupingLoader
    private let invalidateContactsCache: AsyncAction
    private let clearPersonCache: AsyncAction
    private let sleep: Sleep
    private let now: Now
    private let initialPresentationAnchor: InitialPresentationAnchor
    private let taskManager = ViewModelTaskManager()
    private var initialRevealState: InitialRevealState = .waitingForRows
    private var isTrackedBottomAnchorVisible = false
    private var trackedContentMinY: CGFloat?
    private var trackedContentHeight: CGFloat?
    private var trackedViewportHeight: CGFloat?
    private var postRevealBottomFollowState: PostRevealBottomFollowState = .inactive
    private var hasCapturedInitialUnreadSnapshot = false
    private var isVisible = false
    private var pendingAutoReadMessageIDsByEventID: [UUID: [NSManagedObjectID]] = [:]
    private var pendingAutoReadMessageIDsByLayoutID: [UUID: [NSManagedObjectID]] = [:]
    private var pendingAutoReadLayoutOrder: [UUID] = []

    init(
        scrollState: VirtualScrollState,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        initialPresentationAnchor: InitialPresentationAnchor,
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.loadLatestWindowIfNeeded = { knownTotalCount in
            await scrollState.loadLatestWindowIfNeeded(knownTotalCount: knownTotalCount)
        }
        self.markConversationAsReadIfNeeded = {
            viewModel.markConversationAsReadIfNeeded()
        }
        self.markUnreadInboxMessagesAsReadIfNeeded = { messageObjectIDs in
            viewModel.markUnreadInboxMessagesAsReadIfNeeded(messageObjectIDs: messageObjectIDs)
        }
        self.initializeReplyingTo = { lastMessage in
            viewModel.initializeReplyingTo(lastMessage: lastMessage)
        }
        self.updateReplyingToIfNewSubject = { lastMessage in
            viewModel.updateReplyingToIfNewSubject(lastMessage: lastMessage)
        }
        self.loadResolvedDisplayName = {
            viewModel.loadResolvedDisplayName()
        }
        self.prefetchRecentContent = { messageIds, senderEmails in
            viewModel.prefetchRecentContent(messageIds: messageIds, senderEmails: senderEmails)
        }
        self.cancelPrefetch = {
            viewModel.cancelPrefetch()
        }
        self.loadSenderGroupingKeys = { senderEmails in
            await chatDependencies.contacts.participantLoader.senderGroupingKeys(for: senderEmails)
        }
        self.invalidateContactsCache = chatDependencies.contacts.invalidateContactsCache
        self.clearPersonCache = chatDependencies.contacts.clearPersonCache
        self.sleep = sleep
        self.now = now
        self.initialPresentationAnchor = initialPresentationAnchor
    }

    init(
        initialPresentationAnchor: InitialPresentationAnchor = .bottom,
        loadLatestWindowIfNeeded: @escaping LatestWindowLoader,
        markConversationAsReadIfNeeded: @escaping () -> Void,
        markUnreadInboxMessagesAsReadIfNeeded: @escaping ([NSManagedObjectID]) -> Void = { _ in },
        initializeReplyingTo: @escaping (Message?) -> Void,
        updateReplyingToIfNewSubject: @escaping (Message?) -> Void,
        loadResolvedDisplayName: @escaping () -> Void,
        prefetchRecentContent: @escaping ([String], [String]) -> Void,
        cancelPrefetch: @escaping () -> Void,
        loadSenderGroupingKeys: @escaping SenderGroupingLoader,
        invalidateContactsCache: @escaping AsyncAction,
        clearPersonCache: @escaping AsyncAction,
        sleep: @escaping Sleep,
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.loadLatestWindowIfNeeded = loadLatestWindowIfNeeded
        self.markConversationAsReadIfNeeded = markConversationAsReadIfNeeded
        self.markUnreadInboxMessagesAsReadIfNeeded = markUnreadInboxMessagesAsReadIfNeeded
        self.initializeReplyingTo = initializeReplyingTo
        self.updateReplyingToIfNewSubject = updateReplyingToIfNewSubject
        self.loadResolvedDisplayName = loadResolvedDisplayName
        self.prefetchRecentContent = prefetchRecentContent
        self.cancelPrefetch = cancelPrefetch
        self.loadSenderGroupingKeys = loadSenderGroupingKeys
        self.invalidateContactsCache = invalidateContactsCache
        self.clearPersonCache = clearPersonCache
        self.sleep = sleep
        self.now = now
        self.initialPresentationAnchor = initialPresentationAnchor
    }

    func handleAppear(
        messageCount: Int,
        lastMessage: Message?,
        visibleMessages: [ChatMessageRowModel],
        senderGroupingMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        isVisible = true
        if !hasCapturedInitialUnreadSnapshot {
            hasCapturedInitialUnreadSnapshot = true
            markConversationAsReadIfNeeded()
        }
        initializeReplyingTo(lastMessage)

        startInitialAnchorIfPossible(
            messageCount: messageCount,
            visibleMessages: visibleMessages,
            totalMessageCount: totalMessageCount,
            isInitialWindowLoaded: isInitialWindowLoaded,
            reason: "appear",
            scrollAction: scrollAction
        )

        loadResolvedDisplayName()
        prefetchVisibleContent(from: visibleMessages)
        refreshSenderGroupingKeys(using: senderGroupingMessages)
    }

    func handleInitialWindowLoaded(
        messageCount: Int,
        visibleMessages: [ChatMessageRowModel],
        senderGroupingMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView initial window loaded messages=\(messageCount) visible=\(visibleMessages.count) total=\(totalMessageCount)",
            category: .ui
        )
        startInitialAnchorIfPossible(
            messageCount: messageCount,
            visibleMessages: visibleMessages,
            totalMessageCount: totalMessageCount,
            isInitialWindowLoaded: true,
            reason: "initial-window-loaded",
            scrollAction: scrollAction
        )
        prefetchVisibleContent(from: visibleMessages)
        refreshSenderGroupingKeys(using: senderGroupingMessages)
    }

    func handleDisappear() {
        isVisible = false
        postRevealBottomFollowState = .inactive
        isUserScrollTakeoverActive = false
        pendingAutoReadMessageIDsByEventID.removeAll()
        pendingAutoReadMessageIDsByLayoutID.removeAll()
        pendingAutoReadLayoutOrder.removeAll()
        taskManager.cancelAll()
        cancelPrefetch()
        if !isReadyToShow {
            initialRevealState = .waitingForRows
        }
    }

    func handleDisplayedMessagesChange(
        oldIDs: [NSManagedObjectID],
        newIDs: [NSManagedObjectID],
        visibleMessages: [ChatMessageRowModel],
        senderGroupingMessages: [ChatMessageRowModel],
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        startInitialAnchorIfPossible(
            messageCount: messageCount,
            visibleMessages: visibleMessages,
            totalMessageCount: totalMessageCount,
            isInitialWindowLoaded: isInitialWindowLoaded,
            reason: "displayed-messages-change",
            scrollAction: scrollAction
        )

        if oldIDs != newIDs {
            prefetchVisibleContent(from: visibleMessages)
            refreshSenderGroupingKeys(using: senderGroupingMessages)
        }
    }

    func handleInsertedVisibleMessageEvent(
        _ event: VirtualScrollInsertedMessageEvent,
        isChatActiveAndUncovered: Bool,
        isShowingLatestWindow: Bool,
        isBottomAnchorVisible: Bool
    ) {
        guard !event.messageIDs.isEmpty,
              isReadyToShow,
              isVisible,
              isChatActiveAndUncovered,
              isShowingLatestWindow,
              isBottomAnchorVisible else {
            return
        }

        pendingAutoReadMessageIDsByEventID[event.id] = event.messageIDs
    }

    func handleRefreshedInsertedMessageEvent(
        _ refresh: VirtualScrollInsertedMessageRefresh,
        isChatActiveAndUncovered: Bool,
        isShowingLatestWindow: Bool
    ) {
        guard let pendingMessageIDs = pendingAutoReadMessageIDsByEventID.removeValue(
            forKey: refresh.eventID
        ) else {
            return
        }

        let latestWindowMessageIDs = Set(refresh.messageIDsInLatestWindow)
        let verifiedMessageIDs = pendingMessageIDs.filter(latestWindowMessageIDs.contains)
        guard !verifiedMessageIDs.isEmpty,
              isReadyToShow,
              isVisible,
              isChatActiveAndUncovered,
              isShowingLatestWindow else {
            return
        }

        if pendingAutoReadMessageIDsByLayoutID[refresh.layoutID] == nil {
            pendingAutoReadLayoutOrder.append(refresh.layoutID)
        }
        pendingAutoReadMessageIDsByLayoutID[refresh.layoutID, default: []]
            .append(contentsOf: verifiedMessageIDs)
    }

    func handleLatestWindowLayout(
        layoutID: UUID,
        isChatActiveAndUncovered: Bool,
        isShowingLatestWindow: Bool,
        isBottomAnchorVisible: Bool
    ) {
        guard let targetIndex = pendingAutoReadLayoutOrder.firstIndex(of: layoutID) else {
            return
        }

        let layoutIDsToResolve = Array(pendingAutoReadLayoutOrder.prefix(targetIndex + 1))
        pendingAutoReadLayoutOrder.removeFirst(targetIndex + 1)
        let pendingMessageIDs = layoutIDsToResolve.flatMap {
            pendingAutoReadMessageIDsByLayoutID.removeValue(forKey: $0) ?? []
        }

        guard isReadyToShow,
              isVisible,
              isChatActiveAndUncovered,
              isShowingLatestWindow,
              isBottomAnchorVisible else {
            return
        }

        var seenMessageIDs = Set<NSManagedObjectID>()
        let verifiedMessageIDs = pendingMessageIDs.filter { seenMessageIDs.insert($0).inserted }
        markUnreadInboxMessagesAsReadIfNeeded(verifiedMessageIDs)
    }

    /// Advances the initial reveal only from actual bottom-anchor geometry.
    ///
    /// Call this whenever the bottom anchor first lays out or its frame/viewport changes.
    /// A visible anchor starts a delayed confirmation. The content is revealed only if
    /// the anchor remains visible through that delay. If late layout moves the anchor
    /// offscreen, up to two nonanimated scrolls are requested. The content is revealed
    /// as a fallback after both attempts so a bad geometry signal cannot block the chat.
    func handleBottomAnchorGeometryUpdate(
        isBottomAnchorVisible: Bool,
        isUserScrollInteractionActive: Bool = false,
        contentMinY: CGFloat? = nil,
        contentHeight: CGFloat? = nil,
        viewportHeight: CGFloat? = nil,
        scrollAction: @escaping BottomAnchorAction
    ) {
        let previousContentMinY = trackedContentMinY
        let previousContentHeight = trackedContentHeight
        let previousViewportHeight = trackedViewportHeight
        isTrackedBottomAnchorVisible = isBottomAnchorVisible
        if let contentMinY {
            trackedContentMinY = contentMinY
        }
        if let contentHeight {
            trackedContentHeight = contentHeight
        }
        if let viewportHeight {
            trackedViewportHeight = viewportHeight
        }
        updateUserScrollTakeoverRelease(
            isBottomAnchorVisible: isBottomAnchorVisible,
            isUserScrollInteractionActive: isUserScrollInteractionActive
        )

        let contentHeightIncreased: Bool
        if let previousContentHeight, let contentHeight {
            contentHeightIncreased =
                contentHeight > previousContentHeight + Self.geometryChangeTolerance
        } else {
            contentHeightIncreased = false
        }

        // The content frame moves down when the offset moves toward older messages,
        // while a pure height increase leaves its origin unchanged.
        let contentMovedTowardHistory: Bool
        if let previousContentMinY, let contentMinY {
            contentMovedTowardHistory =
                contentMinY > previousContentMinY + Self.geometryChangeTolerance
        } else {
            contentMovedTowardHistory = false
        }

        let viewportHeightDecreased: Bool
        if let previousViewportHeight, let viewportHeight {
            viewportHeightDecreased =
                viewportHeight < previousViewportHeight - Self.geometryChangeTolerance
        } else {
            viewportHeightDecreased = false
        }

        switch postRevealBottomFollowState {
        case .following(let deadline):
            guard now() < deadline else {
                postRevealBottomFollowState = .inactive
                return
            }
            guard !isBottomAnchorVisible else { return }

            if contentMovedTowardHistory {
                cancelPostRevealBottomFollowForNonLayoutScroll()
                return
            }
            guard contentHeightIncreased || viewportHeightDecreased else { return }

            requestPostRevealBottomScroll(
                deadline: deadline,
                scrollAttempts: 1,
                scrollAction: scrollAction
            )
            return
        case .checkingAfterScroll(let deadline, _):
            guard now() < deadline else {
                postRevealBottomFollowState = .inactive
                taskManager.cancel(TaskKey.postRevealGeometryCheck)
                return
            }
            if isBottomAnchorVisible {
                postRevealBottomFollowState = .following(deadline: deadline)
                taskManager.cancel(TaskKey.postRevealGeometryCheck)
                return
            }
            guard !contentMovedTowardHistory else {
                cancelPostRevealBottomFollowForNonLayoutScroll()
                return
            }
            return
        case .waitingForGrowth(let deadline):
            guard now() < deadline else {
                postRevealBottomFollowState = .inactive
                return
            }
            if isBottomAnchorVisible {
                postRevealBottomFollowState = .following(deadline: deadline)
                return
            }
            if contentMovedTowardHistory {
                cancelPostRevealBottomFollowForNonLayoutScroll()
                return
            }
            if contentHeightIncreased || viewportHeightDecreased {
                requestPostRevealBottomScroll(
                    deadline: deadline,
                    scrollAttempts: 1,
                    scrollAction: scrollAction
                )
                return
            }
            return
        case .inactive:
            break
        }

        guard case let .pending(scrollAttempts, phase) = initialRevealState else { return }

        if isBottomAnchorVisible {
            if phase == .validatingVisibility {
                completeInitialReveal(wasVisiblyConfirmed: true)
                return
            }
            guard phase != .confirmingVisibility else { return }
            beginInitialVisibilityConfirmation(scrollAttempts: scrollAttempts)
            return
        }

        guard phase != .checkingAfterScroll else { return }
        guard scrollAttempts < Self.maximumInitialScrollAttempts else {
            completeInitialReveal(wasVisiblyConfirmed: false)
            return
        }

        let nextAttempt = scrollAttempts + 1
        initialRevealState = .pending(
            scrollAttempts: nextAttempt,
            phase: .checkingAfterScroll
        )
        taskManager.run(TaskKey.initialGeometryCheck) { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let self,
                  case .pending(let currentAttempts, .checkingAfterScroll) =
                    self.initialRevealState,
                  currentAttempts == nextAttempt else {
                return
            }
            self.initialRevealState = .pending(
                scrollAttempts: currentAttempts,
                phase: .awaitingGeometry
            )
            self.initialAnchorGeometryCheckID = UUID()
        }
        scrollAction(
            BottomAnchorStep(
                delay: 0,
                animated: false,
                logMessage: nextAttempt == 1
                    ? "ChatView initial layout scroll -> bottom anchor"
                    : "ChatView initial layout retry -> bottom anchor"
            )
        )
    }

    /// Stops initial auto-anchoring and post-reveal bottom following once the user
    /// takes control of the scroll view.
    func handleUserScrollInteraction() {
        isUserScrollTakeoverActive = true
        taskManager.cancel(TaskKey.scrollTakeoverRelease)
        let wasFollowingPostRevealBottom: Bool
        switch postRevealBottomFollowState {
        case .following, .checkingAfterScroll, .waitingForGrowth:
            wasFollowingPostRevealBottom = true
        case .inactive:
            wasFollowingPostRevealBottom = false
        }
        postRevealBottomFollowState = .inactive
        taskManager.cancel(TaskKey.bottomAnchor)
        taskManager.cancel(TaskKey.initialBottomAnchor)
        taskManager.cancel(TaskKey.initialGeometryCheck)
        taskManager.cancel(TaskKey.latestWindow)
        taskManager.cancel(TaskKey.postRevealGeometryCheck)

        guard case .pending = initialRevealState else {
            if wasFollowingPostRevealBottom {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView post-reveal bottom follow cancelled by user scroll",
                    category: .ui
                )
            }
            return
        }

        initialRevealState = .ready(wasEmptyConversation: false)
        isReadyToShow = true
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView initial anchor cancelled by user scroll",
            category: .ui
        )
    }

    func handleMessageCountChange(
        oldCount: Int,
        newCount: Int,
        lastMessage: Message?,
        visibleMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        stabilizeBottomAnchor: Bool,
        isInitialWindowLoaded: Bool,
        isShowingLatestWindow: Bool,
        isBottomAnchorVisible: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        if oldCount == 0 && newCount > 0 {
            updateReplyingToIfNewSubject(lastMessage)
            if hasStartedInitialAnchor && !initialAnchorWasForEmptyConversation {
                if initialPresentationAnchor == .bottom && isInitialWindowLoaded {
                    requestLatestWindowIfNeeded(knownTotalCount: newCount)
                }
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView empty-to-loaded count change handled after initial presentation started messages=\(newCount)",
                    category: .ui
                )
            } else {
                isReadyToShow = false
                initialRevealState = .waitingForRows
                if initialPresentationAnchor == .bottom && isInitialWindowLoaded {
                    requestLatestWindowIfNeeded(knownTotalCount: newCount)
                }
                startInitialAnchorIfPossible(
                    messageCount: newCount,
                    visibleMessages: visibleMessages,
                    totalMessageCount: max(totalMessageCount, newCount),
                    isInitialWindowLoaded: isInitialWindowLoaded,
                    reason: "message-count-change",
                    scrollAction: scrollAction
                )
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView empty-to-loaded count change uses initial anchoring messages=\(newCount) initialWindowLoaded=\(isInitialWindowLoaded)",
                    category: .ui
                )
            }
        } else if !isInitialWindowLoaded {
            if newCount > oldCount {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView deferring message-count presentation until initial window loads old=\(oldCount) new=\(newCount)",
                    category: .ui
                )
            }
        } else if !isReadyToShow && newCount > 0 {
            if initialPresentationAnchor == .bottom && newCount > oldCount {
                requestLatestWindowIfNeeded(knownTotalCount: newCount)
            }
            startInitialAnchorIfPossible(
                messageCount: newCount,
                visibleMessages: visibleMessages,
                totalMessageCount: max(totalMessageCount, newCount),
                isInitialWindowLoaded: isInitialWindowLoaded,
                reason: "message-count-change",
                scrollAction: scrollAction
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView handling count-change before initial reveal completes messages=\(newCount)",
                category: .ui
            )
        } else if isReadyToShow && newCount > oldCount && isShowingLatestWindow {
            updateReplyingToIfNewSubject(lastMessage)
            if isBottomAnchorVisible && !isUserScrollTakeoverActive {
                scrollToBottom(
                    messageCount: newCount,
                    delay: UIConfig.contentChangeScrollDelay,
                    includeStabilizationStep: stabilizeBottomAnchor,
                    knownTotalCount: newCount,
                    scrollAction: scrollAction
                )
            }
        }

        loadResolvedDisplayName()
    }

    private func updateUserScrollTakeoverRelease(
        isBottomAnchorVisible: Bool,
        isUserScrollInteractionActive: Bool
    ) {
        guard isUserScrollTakeoverActive else { return }
        guard isBottomAnchorVisible && !isUserScrollInteractionActive else {
            taskManager.cancel(TaskKey.scrollTakeoverRelease)
            return
        }

        taskManager.run(TaskKey.scrollTakeoverRelease) { [weak self, sleep] in
            await sleep(UInt64(UIConfig.initialScrollDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.isUserScrollTakeoverActive,
                  self.isTrackedBottomAnchorVisible else {
                return
            }
            self.isUserScrollTakeoverActive = false
        }
    }

    func handleKeyboardHeightChange(
        oldHeight: CGFloat,
        newHeight: CGFloat,
        messageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isInitialWindowLoaded, isReadyToShow else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping keyboard bottom anchor before initial reveal loaded=\(isInitialWindowLoaded) ready=\(isReadyToShow)",
                category: .ui
            )
            return
        }

        if newHeight > 0 || (oldHeight > 0 && newHeight == 0) {
            scrollToBottom(
                messageCount: messageCount,
                delay: UIConfig.contentChangeScrollDelay,
                scrollAction: scrollAction
            )
        }
    }

    func handleTextFieldFocusChange(
        isFocused: Bool,
        messageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isInitialWindowLoaded, isReadyToShow else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping focus bottom anchor before initial reveal loaded=\(isInitialWindowLoaded) ready=\(isReadyToShow)",
                category: .ui
            )
            return
        }

        if !isFocused {
            scrollToBottom(
                messageCount: messageCount,
                delay: UIConfig.initialScrollDelay,
                scrollAction: scrollAction
            )
        }
    }

    func handleReplySendCompleted(
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isInitialWindowLoaded else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView deferring post-send refresh until initial window loads messages=\(messageCount) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        let anchorMessageCount = max(messageCount, totalMessageCount)
        guard anchorMessageCount > 0 else { return }

        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView post-send refresh requested messages=\(messageCount) total=\(totalMessageCount)",
            category: .ui
        )
        scrollToBottom(
            messageCount: anchorMessageCount,
            delay: UIConfig.contentChangeScrollDelay,
            includeStabilizationStep: true,
            knownTotalCount: anchorMessageCount,
            scrollAction: scrollAction
        )
    }

    func handleContactStoreDidChange(senderGroupingMessages: [ChatMessageRowModel]) {
        taskManager.run("contactRefresh") { [invalidateContactsCache, clearPersonCache] in
            await invalidateContactsCache()
            await clearPersonCache()

            guard !Task.isCancelled else { return }

            self.contactRefreshToken &+= 1
            self.loadResolvedDisplayName()
            self.refreshSenderGroupingKeys(using: senderGroupingMessages)
        }
    }

    func handlePersonDisplayInfoDidChange(senderGroupingMessages: [ChatMessageRowModel]) {
        contactRefreshToken &+= 1
        loadResolvedDisplayName()
        refreshSenderGroupingKeys(using: senderGroupingMessages)
    }

    func senderRunKey(
        for message: ChatMessageRowModel?,
        isEffectivelyOneToOneConversation: Bool
    ) -> String? {
        guard let message else { return nil }
        guard !message.isFromMe else { return "me" }
        guard let senderEmail = senderEmail(for: message) else { return "email:" }

        let normalizedEmail = EmailNormalizer.normalize(senderEmail)
        if isEffectivelyOneToOneConversation {
            return senderGroupingKeysByEmail[normalizedEmail] ?? "email:\(normalizedEmail)"
        }

        return "email:\(normalizedEmail)"
    }

    private func prefetchVisibleContent(from visibleMessages: [ChatMessageRowModel]) {
        let config = VirtualScrollConfiguration.default
        let prefetchLimit = config.visibleItemCount + config.bufferSize
        let recentMessages = visibleMessages.suffix(prefetchLimit)
        let messageIds = recentMessages
            .filter { message in
                message.chatPreviewText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true
            }
            .map(\.id)
        let senderEmails = recentMessages.compactMap(\.senderEmail)

        prefetchRecentContent(messageIds, senderEmails)
    }

    private func refreshSenderGroupingKeys(using visibleMessages: [ChatMessageRowModel]) {
        var uniqueSenderEmails: [String] = []
        var seenEmails = Set<String>()
        for message in visibleMessages {
            guard let email = senderEmail(for: message) else { continue }
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  seenEmails.insert(normalizedEmail).inserted else {
                continue
            }
            uniqueSenderEmails.append(email)
        }

        taskManager.run("senderGrouping") { [loadSenderGroupingKeys] in
            let groupingKeys = await loadSenderGroupingKeys(uniqueSenderEmails)
            guard !Task.isCancelled else { return }
            self.senderGroupingKeysByEmail = groupingKeys
        }
    }

    private func senderEmail(for message: ChatMessageRowModel) -> String? {
        if let senderEmail = message.senderGroupingKeyInput?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !senderEmail.isEmpty {
            return senderEmail
        }

        return nil
    }

    private func startInitialAnchorIfPossible(
        messageCount: Int,
        visibleMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        reason: String,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard !isReadyToShow else { return }

        let anchorMessageCount = max(messageCount, totalMessageCount)

        guard anchorMessageCount > 0 else {
            initialRevealState = .ready(wasEmptyConversation: true)
            isReadyToShow = true
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor skipped for empty conversation reason=\(reason)",
                category: .ui
            )
            return
        }

        guard isInitialWindowLoaded else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor deferred until virtual window loads reason=\(reason) messages=\(messageCount) visible=\(visibleMessages.count) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        guard !visibleMessages.isEmpty else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor waiting for visible rows reason=\(reason) messages=\(messageCount) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        if initialPresentationAnchor == .top {
            initialRevealState = .ready(wasEmptyConversation: false)
            isReadyToShow = true
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial rows revealed at top reason=\(reason) messages=\(anchorMessageCount)",
                category: .ui
            )
            return
        }

        performInitialScroll(messageCount: anchorMessageCount, reason: reason)
    }

    private func performInitialScroll(
        messageCount: Int,
        reason: String
    ) {
        guard !hasStartedInitialAnchor else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor already scheduled reason=\(reason) messages=\(messageCount)",
                category: .ui
            )
            return
        }

        initialRevealState = .pending(
            scrollAttempts: 0,
            phase: .awaitingGeometry
        )
        initialAnchorGeometryCheckID = UUID()
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView initial anchor awaiting layout reason=\(reason) messages=\(messageCount)",
            category: .ui
        )
        if messageCount > 1 {
            taskManager.run(TaskKey.initialBottomAnchor) { [loadLatestWindowIfNeeded] in
                await loadLatestWindowIfNeeded(nil)
            }
        }
    }

    private var hasStartedInitialAnchor: Bool {
        initialRevealState != .waitingForRows
    }

    private var initialAnchorWasForEmptyConversation: Bool {
        initialRevealState == .ready(wasEmptyConversation: true)
    }

    private func beginInitialVisibilityConfirmation(scrollAttempts: Int) {
        initialRevealState = .pending(
            scrollAttempts: scrollAttempts,
            phase: .confirmingVisibility
        )
        taskManager.run(TaskKey.initialGeometryCheck) { [weak self, sleep] in
            await sleep(UInt64(UIConfig.initialScrollDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  case .pending(let currentAttempts, .confirmingVisibility) =
                    self.initialRevealState,
                  currentAttempts == scrollAttempts,
                  self.isTrackedBottomAnchorVisible else {
                return
            }
            self.initialRevealState = .pending(
                scrollAttempts: currentAttempts,
                phase: .validatingVisibility
            )
            self.initialAnchorGeometryCheckID = UUID()
        }
    }

    private func requestPostRevealBottomScroll(
        deadline: TimeInterval,
        scrollAttempts: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard now() < deadline else {
            postRevealBottomFollowState = .inactive
            return
        }

        postRevealBottomFollowState = .checkingAfterScroll(
            deadline: deadline,
            scrollAttempts: scrollAttempts
        )
        taskManager.run(TaskKey.postRevealGeometryCheck) { [weak self, sleep] in
            await sleep(UInt64(UIConfig.initialScrollDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  case .checkingAfterScroll(let currentDeadline, let currentAttempts) =
                    self.postRevealBottomFollowState,
                  currentDeadline == deadline,
                  currentAttempts == scrollAttempts else {
                return
            }
            self.validatePostRevealBottomScroll(
                deadline: currentDeadline,
                scrollAttempts: currentAttempts,
                scrollAction: scrollAction
            )
        }
        scrollAction(
            BottomAnchorStep(
                delay: 0,
                animated: false,
                logMessage: scrollAttempts == 1
                    ? "ChatView post-reveal layout scroll -> bottom anchor"
                    : "ChatView post-reveal layout retry -> bottom anchor"
            )
        )
    }

    private func cancelPostRevealBottomFollowForNonLayoutScroll() {
        postRevealBottomFollowState = .inactive
        taskManager.cancel(TaskKey.postRevealGeometryCheck)
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView post-reveal bottom follow cancelled by non-layout scroll",
            category: .ui
        )
    }

    private func validatePostRevealBottomScroll(
        deadline: TimeInterval,
        scrollAttempts: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard now() < deadline else {
            postRevealBottomFollowState = .inactive
            return
        }
        guard !isTrackedBottomAnchorVisible else {
            postRevealBottomFollowState = .following(deadline: deadline)
            return
        }
        guard scrollAttempts < Self.maximumPostRevealScrollAttempts else {
            postRevealBottomFollowState = .waitingForGrowth(deadline: deadline)
            return
        }

        requestPostRevealBottomScroll(
            deadline: deadline,
            scrollAttempts: scrollAttempts + 1,
            scrollAction: scrollAction
        )
    }

    private func completeInitialReveal(wasVisiblyConfirmed: Bool) {
        guard case .pending = initialRevealState else { return }

        initialRevealState = .ready(wasEmptyConversation: false)
        postRevealBottomFollowState = wasVisiblyConfirmed
            ? .following(deadline: now() + Self.postRevealBottomFollowGracePeriod)
            : .inactive
        isReadyToShow = true
        Log.diagnostic(
            .chatView,
            level: wasVisiblyConfirmed ? .info : .warning,
            wasVisiblyConfirmed
                ? "ChatView initial anchor remained visible through stabilization"
                : "ChatView initial anchor attempts exhausted; revealing fallback",
            category: .ui
        )
    }

    private func requestLatestWindowIfNeeded(knownTotalCount: Int?) {
        taskManager.run(TaskKey.latestWindow) { [loadLatestWindowIfNeeded] in
            await loadLatestWindowIfNeeded(knownTotalCount)
        }
    }

    private func scrollToBottom(
        messageCount: Int,
        delay: TimeInterval,
        includeStabilizationStep: Bool = false,
        knownTotalCount: Int? = nil,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard messageCount > 0 else { return }

        var steps = [
            BottomAnchorStep(
                delay: delay,
                animated: true,
                logMessage: "ChatView animated scroll -> bottom anchor"
            )
        ]

        if includeStabilizationStep {
            steps.append(
                BottomAnchorStep(
                    delay: max(UIConfig.initialScrollDelay, UIConfig.scrollAnimationDuration),
                    animated: false,
                    logMessage: "ChatView stabilization scroll after content change -> bottom anchor"
                )
            )
        }

        scheduleBottomAnchor(
            taskKey: TaskKey.bottomAnchor,
            knownTotalCount: knownTotalCount,
            steps: steps,
            scrollAction: scrollAction
        )
    }

    private func scheduleBottomAnchor(
        taskKey: String,
        knownTotalCount: Int? = nil,
        steps: [BottomAnchorStep],
        scrollAction: @escaping BottomAnchorAction
    ) {
        taskManager.run(taskKey) { [loadLatestWindowIfNeeded, sleep] in
            await loadLatestWindowIfNeeded(knownTotalCount)

            for step in steps {
                if step.delay > 0 {
                    await sleep(UInt64(step.delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                await loadLatestWindowIfNeeded(knownTotalCount)
                guard !Task.isCancelled else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }

                scrollAction(step)
            }
        }
    }
}
