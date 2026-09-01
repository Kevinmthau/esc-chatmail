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
        static func optimisticReplyPublication(_ messageObjectID: NSManagedObjectID) -> String {
            "optimisticReplyPublication.\(messageObjectID.uriRepresentation().absoluteString)"
        }
        static func replyAdmissionStabilization(_ messageObjectID: NSManagedObjectID) -> String {
            "replyAdmissionStabilization.\(messageObjectID.uriRepresentation().absoluteString)"
        }
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

    private struct OptimisticReplyPublicationAttempt {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private static let maximumInitialScrollAttempts = 2
    private static let maximumPostRevealScrollAttempts = 2
    private static let postRevealBottomFollowGracePeriod: TimeInterval = 3.0
    private static let geometryChangeTolerance: CGFloat = 0.5
    /// Hard wall-clock bound on the hidden initial-anchor pass. The retry
    /// budget resets whenever content legitimately grows (async bubble loads),
    /// so an event count alone no longer terminates the pass; this deadline
    /// does, revealing the transcript rather than holding the spinner.
    private static let initialAnchorRevealTimeLimit: TimeInterval = 3.0
    /// Absolute cap on how far growth can keep sliding the post-reveal
    /// bottom-follow deadline past its arm time. Sliding exists so bubbles
    /// that finish resizing late still re-anchor; without a cap, a layout
    /// whose measured height never converges (an oscillating web bubble, a
    /// retrying remote image) would keep the follow — and its corrective
    /// scroll bursts — alive indefinitely.
    private static let maximumPostRevealBottomFollowLifetime: TimeInterval = 30.0

    struct BottomAnchorStep: Equatable {
        let delay: TimeInterval
        let animated: Bool
        let logMessage: String
    }

    struct PostSendAnchorIntent: Equatable {
        fileprivate let userScrollInteractionRevision: UInt
    }

    typealias BottomAnchorAction = @MainActor (BottomAnchorStep) -> Void
    typealias SenderGroupingLoader = ([String]) async -> [String: String]
    typealias AsyncAction = () async -> Void
    typealias LatestWindowLoader = (Int?) async -> Void
    typealias MessageVisibilityEnsurer = (NSManagedObjectID) async -> Bool
    typealias Sleep = (UInt64) async -> Void
    typealias Now = () -> TimeInterval

    @Published private(set) var isReadyToShow = false
    /// True while readiness came from revealing an empty conversation — the
    /// one ready state `handleMessageCountChange` restarts a hidden reveal
    /// from when messages arrive. The view must not treat it as a terminal
    /// reveal (releasing the initial-anchor hold on a re-publish against it
    /// would strip the restarted pass of its onAppear protection).
    var isRevealRestartableFromEmpty: Bool {
        initialRevealState == .ready(wasEmptyConversation: true)
    }
    @Published private(set) var contactRefreshToken = 0
    @Published private(set) var senderGroupingKeysByEmail: [String: String] = [:]
    @Published private(set) var initialAnchorGeometryCheckID = UUID()
    @Published private(set) var isUserScrollTakeoverActive = false

    private let loadLatestWindowIfNeeded: LatestWindowLoader
    private let ensureVisibleMessage: MessageVisibilityEnsurer
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
    /// Wall-clock deadline for the pending initial-anchor pass; armed by
    /// `performInitialScroll`, cleared on completion. Consulted only while
    /// `initialRevealState` is `.pending`.
    private var initialAnchorRevealDeadline: TimeInterval?
    /// Whether any geometry update has carried a laid-out bottom-anchor frame
    /// this reveal pass. Until then, "anchor offscreen" only means "the lazy
    /// trailing anchor has not been realized", so it must not consume the
    /// bounded retry budget — and a wall-clock fallback without it means the
    /// geometry signal never proved itself, so no bottom-follow is armed.
    private var hasObservedBottomAnchorGeometry = false
    /// Growth latches: every geometry event overwrites the tracked
    /// content/viewport values at the top of `handleBottomAnchorGeometryUpdate`
    /// — including events the `.checkingAfterScroll` phases then swallow. The
    /// machines spend most of a pass inside those phases (checking is entered
    /// synchronously on each probe, the between state lasts about one frame),
    /// so without a latch the swallowed events would permanently consume their
    /// growth deltas and the growth-aware budget reset / deadline slide would
    /// almost never see production growth. The latch records the swallowed
    /// observation for the next probe (initial) or validation (post-reveal).
    private var didObserveGrowthDuringInitialRecheck = false
    private var didObserveGrowthDuringPostRevealCheck = false
    /// When the current post-reveal follow was armed; bounds deadline sliding
    /// via `maximumPostRevealBottomFollowLifetime`.
    private var postRevealBottomFollowArmedAt: TimeInterval = 0
    private var isTrackedBottomAnchorVisible = false
    private var trackedContentMinY: CGFloat?
    private var trackedContentHeight: CGFloat?
    private var trackedViewportHeight: CGFloat?
    private var postRevealBottomFollowState: PostRevealBottomFollowState = .inactive
    private var hasCapturedInitialUnreadSnapshot = false
    private var isVisible = false
    private var userScrollInteractionRevision: UInt = 0
    private var optimisticReplyPublicationAttempts: [
        NSManagedObjectID: OptimisticReplyPublicationAttempt
    ] = [:]
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
        self.ensureVisibleMessage = { messageObjectID in
            await scrollState.ensureVisibleMessage(messageObjectID)
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
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime },
        ensureVisibleMessage: @escaping MessageVisibilityEnsurer = { _ in true }
    ) {
        self.loadLatestWindowIfNeeded = loadLatestWindowIfNeeded
        self.ensureVisibleMessage = ensureVisibleMessage
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
        didObserveGrowthDuringInitialRecheck = false
        didObserveGrowthDuringPostRevealCheck = false
        isUserScrollTakeoverActive = false
        pendingAutoReadMessageIDsByEventID.removeAll()
        pendingAutoReadMessageIDsByLayoutID.removeAll()
        pendingAutoReadLayoutOrder.removeAll()
        optimisticReplyPublicationAttempts.values.forEach { $0.task.cancel() }
        optimisticReplyPublicationAttempts.removeAll()
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
        // Deliberately no default: "offscreen" with a never-laid-out anchor
        // frame must not charge the initial retry budget, so every caller
        // decides this explicitly. (Tests use a defaulted overload in their
        // own target.)
        hasBottomAnchorGeometry: Bool,
        isUserScrollInteractionActive: Bool = false,
        contentMinY: CGFloat? = nil,
        contentHeight: CGFloat? = nil,
        viewportHeight: CGFloat? = nil,
        scrollAction: @escaping BottomAnchorAction
    ) {
        let previousContentMinY = trackedContentMinY
        let previousContentHeight = trackedContentHeight
        let previousViewportHeight = trackedViewportHeight
        if hasBottomAnchorGeometry {
            hasObservedBottomAnchorGeometry = true
        }
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

        // A fixed grace abandoned bubbles that finished resizing more than the
        // grace period after reveal, stranding the viewport just above the
        // last message. Growth observed while the follow is alive therefore
        // slides the deadline; a quiet gap longer than the grace still
        // expires it, and user scrolling cancels it outright, so following
        // stays bounded. Not slid in .checkingAfterScroll: the in-flight
        // validation task matches on the exact deadline to detect staleness.
        let didObserveGrowth = contentHeightIncreased || viewportHeightDecreased

        switch postRevealBottomFollowState {
        case .following(let deadline):
            guard now() < deadline else {
                postRevealBottomFollowState = .inactive
                return
            }
            let slidDeadline = didObserveGrowth
                ? slidPostRevealFollowDeadline(extending: deadline)
                : deadline
            guard !isBottomAnchorVisible else {
                if slidDeadline != deadline {
                    postRevealBottomFollowState = .following(deadline: slidDeadline)
                }
                return
            }

            if contentMovedTowardHistory {
                cancelPostRevealBottomFollowForNonLayoutScroll()
                return
            }
            guard didObserveGrowth else { return }

            requestPostRevealBottomScroll(
                deadline: slidDeadline,
                scrollAttempts: 1,
                scrollAction: scrollAction
            )
            return
        case .checkingAfterScroll(let deadline, _):
            guard now() < deadline else {
                postRevealBottomFollowState = .inactive
                didObserveGrowthDuringPostRevealCheck = false
                taskManager.cancel(TaskKey.postRevealGeometryCheck)
                return
            }
            if isBottomAnchorVisible {
                // Leaving .checkingAfterScroll cancels its validation task,
                // so sliding here cannot break the task's deadline-equality
                // staleness check.
                postRevealBottomFollowState = .following(
                    deadline: didObserveGrowth || didObserveGrowthDuringPostRevealCheck
                        ? slidPostRevealFollowDeadline(extending: deadline)
                        : deadline
                )
                didObserveGrowthDuringPostRevealCheck = false
                taskManager.cancel(TaskKey.postRevealGeometryCheck)
                return
            }
            guard !contentMovedTowardHistory else {
                cancelPostRevealBottomFollowForNonLayoutScroll()
                return
            }
            // The in-flight validation matches on the exact deadline, so the
            // slide cannot happen here; latch the growth for the validation
            // to consume instead of discarding it with this event.
            if didObserveGrowth {
                didObserveGrowthDuringPostRevealCheck = true
            }
            return
        case .waitingForGrowth(let deadline):
            guard now() < deadline else {
                postRevealBottomFollowState = .inactive
                return
            }
            let slidDeadline = didObserveGrowth
                ? slidPostRevealFollowDeadline(extending: deadline)
                : deadline
            if isBottomAnchorVisible {
                postRevealBottomFollowState = .following(deadline: slidDeadline)
                return
            }
            if contentMovedTowardHistory {
                cancelPostRevealBottomFollowForNonLayoutScroll()
                return
            }
            if didObserveGrowth {
                requestPostRevealBottomScroll(
                    deadline: slidDeadline,
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
            guard phase != .confirmingVisibility else {
                // Growth landing mid-confirmation is swallowed here after the
                // tracker overwrite consumed its delta; latch it, or the
                // offscreen probes that follow (the growth pushed the anchor
                // off) would charge the budget as if nothing grew.
                if didObserveGrowth {
                    didObserveGrowthDuringInitialRecheck = true
                }
                return
            }
            // The confirmation-entry event can itself carry growth (a bubble
            // resolving in the same layout pass that landed the anchor);
            // latch it like the sibling seams — a confirmed reveal clears
            // the latch, and a failed confirmation needs it to keep the
            // budget growth-aware.
            if didObserveGrowth {
                didObserveGrowthDuringInitialRecheck = true
            }
            beginInitialVisibilityConfirmation(scrollAttempts: scrollAttempts)
            return
        }

        guard phase != .checkingAfterScroll else {
            // This event's tracker overwrite above already consumed its
            // growth delta; latch the observation so the next probe still
            // treats the pass as growing.
            if didObserveGrowth {
                didObserveGrowthDuringInitialRecheck = true
            }
            return
        }

        // The bounded retry budget alone cannot terminate the pass any more
        // (growth resets it below), so a wall-clock deadline does. Growth
        // observed during the pass proves the geometry signal works, which is
        // what justifies arming bottom-follow on this fallback — unlike the
        // attempts-exhausted fallback, whose steady offscreen reports mean
        // the signal cannot be trusted to drive further scrolls.
        if let revealDeadline = initialAnchorRevealDeadline, now() >= revealDeadline {
            completeInitialReveal(
                wasVisiblyConfirmed: false,
                armsBottomFollowAfterFallback: hasObservedBottomAnchorGeometry
            )
            return
        }

        // Content growth (a bubble's async placeholder-to-content swap, the
        // reply bar inset arriving, a window publish) is exactly what the
        // retry exists to absorb — it must not consume the budget. A broken
        // geometry signal produces offscreen reports without height deltas,
        // so the bounded fallback still terminates that case.
        var chargedAttempts = scrollAttempts
        if didObserveGrowth || didObserveGrowthDuringInitialRecheck {
            chargedAttempts = 0
        }
        didObserveGrowthDuringInitialRecheck = false

        // "Offscreen" before the lazy trailing anchor has ever laid out only
        // means "not realized yet"; keep scrolling (registration can land the
        // scroll) but leave the budget untouched until real geometry exists.
        if hasObservedBottomAnchorGeometry {
            guard chargedAttempts < Self.maximumInitialScrollAttempts else {
                completeInitialReveal(wasVisiblyConfirmed: false)
                return
            }
        }

        let nextAttempt = hasObservedBottomAnchorGeometry
            ? chargedAttempts + 1
            : chargedAttempts
        initialRevealState = .pending(
            scrollAttempts: nextAttempt,
            phase: .checkingAfterScroll
        )
        taskManager.run(TaskKey.initialGeometryCheck) { [weak self, sleep] in
            guard !Task.isCancelled else { return }
            // Pace the re-probe like the sibling rechecks in this file: a
            // bare Task.yield() sampled the first, possibly unconverged
            // layout pass of a lazy scroll-to-tail and burned the budget
            // within a couple of commits.
            await sleep(UInt64(UIConfig.initialScrollDelay * 1_000_000_000))
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
                logMessage: nextAttempt <= 1
                    ? "ChatView initial layout scroll -> bottom anchor"
                    : "ChatView initial layout retry -> bottom anchor"
            )
        )
    }

    /// Stops initial auto-anchoring and post-reveal bottom following once the user
    /// takes control of the scroll view.
    func handleUserScrollInteraction() {
        userScrollInteractionRevision &+= 1
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
        didObserveGrowthDuringInitialRecheck = false
        didObserveGrowthDuringPostRevealCheck = false
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
        initialAnchorRevealDeadline = nil
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
                // The restarted reveal owns anchoring; an armed bottom follow
                // would intercept every geometry update before the pending
                // reveal machine could run. Every follow deactivation also
                // clears the growth latch and its validation task, so a
                // phantom observation cannot buy the next follow a scroll.
                postRevealBottomFollowState = .inactive
                didObserveGrowthDuringPostRevealCheck = false
                taskManager.cancel(TaskKey.postRevealGeometryCheck)
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
        guard !isUserScrollTakeoverActive else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping keyboard bottom anchor during user scroll takeover",
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
        guard !isUserScrollTakeoverActive else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping focus bottom anchor during user scroll takeover",
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

    /// Captures which user-scroll interactions predate an explicit local send.
    ///
    /// Existing takeover must not suppress presenting the user's own reply. A
    /// newer interaction suppresses only the optional bottom anchor while the
    /// exact-row publication still completes.
    func capturePostSendAnchorIntent() -> PostSendAnchorIntent {
        PostSendAnchorIntent(
            userScrollInteractionRevision: userScrollInteractionRevision
        )
    }

    func handleReplyOptimisticMessagePersisted(
        targetMessageID: NSManagedObjectID,
        anchorIntent: PostSendAnchorIntent,
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isVisible else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping optimistic reply publication visible=\(isVisible) loaded=\(isInitialWindowLoaded) messages=\(messageCount) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView optimistic reply publication requested messages=\(messageCount) total=\(totalMessageCount)",
            category: .ui
        )
        optimisticReplyPublicationAttempts[targetMessageID]?.task.cancel()
        let publicationAttemptID = UUID()
        let publicationTask = Task { [ensureVisibleMessage] in
            guard !Task.isCancelled else { return false }
            let didPublishTarget = await ensureVisibleMessage(targetMessageID)
            return !Task.isCancelled && didPublishTarget
        }
        optimisticReplyPublicationAttempts[targetMessageID] = .init(
            id: publicationAttemptID,
            task: publicationTask
        )
        taskManager.run(
            TaskKey.optimisticReplyPublication(targetMessageID)
        ) { [weak self, publicationTask] in
            let didPublishTarget = await publicationTask.value
            guard let self else { return }
            self.clearOptimisticReplyPublicationAttempt(
                for: targetMessageID,
                id: publicationAttemptID
            )
            guard !Task.isCancelled, self.isVisible else { return }
            guard didPublishTarget else {
                Log.diagnostic(
                    .chatView,
                    level: .warning,
                    "ChatView optimistic reply was not published; skipping bottom anchor",
                    category: .ui
                )
                return
            }
            guard isInitialWindowLoaded else {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView optimistic reply published before initial window completed; skipping bottom anchor",
                    category: .ui
                )
                return
            }
            guard self.userScrollInteractionRevision ==
                    anchorIntent.userScrollInteractionRevision else {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView optimistic reply published after newer user scroll; preserving takeover",
                    category: .ui
                )
                return
            }

            self.scrollToBottom(
                messageCount: max(1, max(messageCount, totalMessageCount)),
                delay: UIConfig.contentChangeScrollDelay,
                includeStabilizationStep: true,
                reloadLatestWindow: false,
                scrollAction: scrollAction
            )
            // Keep following bounded layout growth while local preflight is
            // still running. Admission refreshes this grace period once more.
            if self.isReadyToShow {
                self.armPostSendBottomFollow()
            }
        }
    }

    /// Reconfirms exact-row publication after local preflight reaches the
    /// durable Gmail-admission boundary, then performs one non-animated
    /// correction for layout or sync-echo growth that happened during preflight.
    func handleReplySendAdmitted(
        targetMessageID: NSManagedObjectID,
        anchorIntent: PostSendAnchorIntent,
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        let effectiveMessageCount = max(messageCount, totalMessageCount)
        let initialPublicationTask = optimisticReplyPublicationAttempts[
            targetMessageID
        ]?.task
        guard isVisible else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping reply-admission publication because the chat is not visible",
                category: .ui
            )
            return
        }

        // Admission is the final exact-row safety net. Delay first so the
        // optimistic path keeps priority, then join any in-flight publication
        // before retrying. VirtualScrollState must never reconcile the same
        // explicit row concurrently from these two send phases.
        taskManager.run(
            TaskKey.replyAdmissionStabilization(targetMessageID)
        ) { [weak self, ensureVisibleMessage, sleep] in
            guard let self else { return }
            let step = BottomAnchorStep(
                delay: max(UIConfig.initialScrollDelay, UIConfig.scrollAnimationDuration),
                animated: false,
                logMessage: "ChatView reply-admission stabilization -> bottom anchor"
            )
            await sleep(UInt64(step.delay * 1_000_000_000))
            guard !Task.isCancelled, self.isVisible else {
                return
            }

            let didPublishTarget: Bool
            if let initialPublicationTask,
               await initialPublicationTask.value {
                didPublishTarget = true
            } else {
                guard !Task.isCancelled, self.isVisible else { return }
                didPublishTarget = await ensureVisibleMessage(targetMessageID)
            }
            guard !Task.isCancelled, self.isVisible else { return }
            guard didPublishTarget else {
                Log.diagnostic(
                    .chatView,
                    level: .warning,
                    "ChatView reply-admission fallback could not publish the optimistic row",
                    category: .ui
                )
                return
            }
            guard isInitialWindowLoaded,
                  self.isReadyToShow,
                  effectiveMessageCount > 0,
                  self.userScrollInteractionRevision ==
                    anchorIntent.userScrollInteractionRevision else {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView published reply at admission without optional stabilization",
                    category: .ui
                )
                return
            }
            scrollAction(step)
            self.armPostSendBottomFollow()
        }
    }

    private func clearOptimisticReplyPublicationAttempt(
        for messageObjectID: NSManagedObjectID,
        id: UUID
    ) {
        guard optimisticReplyPublicationAttempts[messageObjectID]?.id == id else {
            return
        }
        optimisticReplyPublicationAttempts.removeValue(forKey: messageObjectID)
    }

    private func armPostSendBottomFollow() {
        // The sent row can keep changing height as bubble content resolves and
        // the sync echo rewrites it. A fresh bounded follow corrects that late
        // growth while a real user scroll still cancels the behavior.
        didObserveGrowthDuringPostRevealCheck = false
        taskManager.cancel(TaskKey.postRevealGeometryCheck)
        postRevealBottomFollowArmedAt = now()
        postRevealBottomFollowState = .following(
            deadline: postRevealBottomFollowArmedAt
                + Self.postRevealBottomFollowGracePeriod
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
        initialAnchorRevealDeadline = now() + Self.initialAnchorRevealTimeLimit
        hasObservedBottomAnchorGeometry = false
        didObserveGrowthDuringInitialRecheck = false
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
        didObserveGrowthDuringPostRevealCheck = false
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
            didObserveGrowthDuringPostRevealCheck = false
            return
        }
        guard !isTrackedBottomAnchorVisible else {
            postRevealBottomFollowState = .following(
                deadline: didObserveGrowthDuringPostRevealCheck
                    ? slidPostRevealFollowDeadline(extending: deadline)
                    : deadline
            )
            didObserveGrowthDuringPostRevealCheck = false
            return
        }
        guard scrollAttempts < Self.maximumPostRevealScrollAttempts else {
            // Growth swallowed while this scroll's validation was in flight
            // means the anchor target moved under it; parking in
            // .waitingForGrowth would strand the viewport by exactly that
            // delta, because the delta was already consumed and no later
            // event will re-report it. Spend the latch on one more corrective
            // cycle instead.
            if didObserveGrowthDuringPostRevealCheck {
                didObserveGrowthDuringPostRevealCheck = false
                requestPostRevealBottomScroll(
                    deadline: slidPostRevealFollowDeadline(extending: deadline),
                    scrollAttempts: 1,
                    scrollAction: scrollAction
                )
                return
            }
            postRevealBottomFollowState = .waitingForGrowth(deadline: deadline)
            return
        }

        requestPostRevealBottomScroll(
            deadline: deadline,
            scrollAttempts: scrollAttempts + 1,
            scrollAction: scrollAction
        )
    }

    /// Extends a live post-reveal follow deadline for freshly observed
    /// growth, clamped to an absolute lifetime from the follow's arm time so
    /// a never-converging layout cannot keep the follow alive forever.
    private func slidPostRevealFollowDeadline(extending deadline: TimeInterval) -> TimeInterval {
        min(
            max(deadline, now() + Self.postRevealBottomFollowGracePeriod),
            postRevealBottomFollowArmedAt + Self.maximumPostRevealBottomFollowLifetime
        )
    }

    private func completeInitialReveal(
        wasVisiblyConfirmed: Bool,
        armsBottomFollowAfterFallback: Bool = false
    ) {
        guard case .pending = initialRevealState else { return }

        initialRevealState = .ready(wasEmptyConversation: false)
        let armsBottomFollow = wasVisiblyConfirmed || armsBottomFollowAfterFallback
        if armsBottomFollow {
            postRevealBottomFollowArmedAt = now()
            postRevealBottomFollowState = .following(
                deadline: postRevealBottomFollowArmedAt + Self.postRevealBottomFollowGracePeriod
            )
        } else {
            postRevealBottomFollowState = .inactive
        }
        initialAnchorRevealDeadline = nil
        didObserveGrowthDuringInitialRecheck = false
        didObserveGrowthDuringPostRevealCheck = false
        isReadyToShow = true
        let logMessage: String
        if wasVisiblyConfirmed {
            logMessage = "ChatView initial anchor remained visible through stabilization"
        } else if armsBottomFollowAfterFallback {
            logMessage = "ChatView initial anchor time limit reached; revealing with bottom follow"
        } else {
            logMessage = "ChatView initial anchor attempts exhausted; revealing fallback"
        }
        Log.diagnostic(
            .chatView,
            level: wasVisiblyConfirmed ? .info : .warning,
            logMessage,
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
        reloadLatestWindow: Bool = true,
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
            reloadLatestWindow: reloadLatestWindow,
            steps: steps,
            scrollAction: scrollAction
        )
    }

    private func scheduleBottomAnchor(
        taskKey: String,
        knownTotalCount: Int? = nil,
        reloadLatestWindow: Bool = true,
        steps: [BottomAnchorStep],
        scrollAction: @escaping BottomAnchorAction
    ) {
        taskManager.run(taskKey) { [loadLatestWindowIfNeeded, sleep] in
            if reloadLatestWindow {
                await loadLatestWindowIfNeeded(knownTotalCount)
            }
            guard !Task.isCancelled else { return }

            for step in steps {
                if step.delay > 0 {
                    await sleep(UInt64(step.delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                if reloadLatestWindow {
                    await loadLatestWindowIfNeeded(knownTotalCount)
                    guard !Task.isCancelled else { return }
                }
                await Task.yield()
                guard !Task.isCancelled else { return }

                scrollAction(step)
            }
        }
    }
}
