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
        static let compensatedShiftSettle = "compensatedShiftSettle"
        static let scrollTakeoverRelease = "scrollTakeoverRelease"
        static let pastContentEndCorrection = "pastContentEndCorrection"
        static let initialRevealWatchdog = "initialRevealWatchdog"
        static let postRevealAudit = "postRevealAudit"
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

    /// A transcript shift the view is animating to compensate inset growth
    /// (`handleCompensatedInsetGrowth`), during which the bottom follow holds.
    private struct CompensatedShiftHold {
        let until: TimeInterval
        /// Some overlapping shift began with the bottom anchor visible, so the
        /// shift is planned to end at the new bottom. Mid-shift layout (the
        /// lazy stack re-estimating a row by a couple of points) can still
        /// leave it short; the settle check corrects that.
        let startedAtBottom: Bool
        var didObserveGrowth: Bool
        /// False for the short hold that covers the settle check's own
        /// animated anchor (`holdThroughSettleAnchor`): its settle does not
        /// anchor again.
        var anchorsAtSettle = true
    }

    private static let maximumInitialScrollAttempts = 2
    private static let maximumPostRevealScrollAttempts = 2
    private static let postRevealBottomFollowGracePeriod: TimeInterval = 3.0
    private static let geometryChangeTolerance: CGFloat = 0.5
    /// Bottom follow armed when a compensated shift settles at the bottom,
    /// whether or not it started there. During the shift the anchor sat
    /// offscreen, so the view turned off latest-insertion following; a message
    /// that arrived then is appended when the anchor becomes visible again,
    /// usually as the shift ends, and this follow absorbs it. It is an
    /// ordinary post-reveal follow: growth slides it like any other (3s
    /// grace, 30s lifetime), and a user scroll cancels it.
    private static let compensatedShiftSettleFollowGracePeriod: TimeInterval = 1.0
    /// Frame or two after the settle anchor's animation before its hold ends.
    private static let settleAnchorHoldSlack: TimeInterval = 0.1
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
    /// How far the content's bottom edge may sit above the viewport's bottom
    /// edge before the transcript counts as parked past its end
    /// (`isTrackedContentParkedPastEnd`). A transcript anchored at the bottom
    /// measured its content end 0.3-1pt *below* the viewport bottom in the
    /// simulator (never parked), so the value is headroom for a landing a few
    /// points short: a two-step keyboard's return shift lands ~3pt off
    /// (`ChatTranscriptOffsetShifter`), direction unrecorded.
    private static let pastContentEndTolerance: CGFloat = 8
    /// Corrections of a parked transcript before one lands and the geometry
    /// reports it back in range. Bounds a geometry signal that keeps reading
    /// as parked, which would otherwise scroll on every quiet beat.
    private static let maximumConsecutivePastContentEndCorrections = 2
    /// How long after an automatic reveal `schedulePostRevealAudit` looks
    /// at the transcript once more. Well past the past-end correction's quiet
    /// beat (`UIConfig.initialScrollDelay`), so a park still standing then is
    /// one the correction did not, or could not, fix.
    private static let postRevealAuditDelay: TimeInterval = 1.0
    /// How long past the reveal time limit the watchdog waits before it
    /// reveals a still-pending pass itself. A working geometry signal
    /// evaluates the deadline within a re-probe or two of it (each takes
    /// `UIConfig.initialScrollDelay`), so the grace leaves the deadline to
    /// that signal and the watchdog acts only when it has gone quiet.
    private static let initialRevealWatchdogGrace: TimeInterval = 1.0

    /// `Task.sleep`, the default for `sleep` and `watchdogSleep`. A
    /// `nonisolated` function rather than a stored closure: the initializers'
    /// default-argument expressions evaluate outside the main actor, where a
    /// main-actor-isolated static property cannot be referenced (a compile
    /// error under this project's language mode, not a warning).
    nonisolated static func systemSleep(_ nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    struct BottomAnchorStep: Equatable {
        let delay: TimeInterval
        let animated: Bool
        let logMessage: String
    }

    struct PostSendAnchorIntent: Equatable {
        fileprivate let userScrollInteractionRevision: UInt
        /// Set only by `beginLocalReplySend`, which registers the send as in
        /// flight until `endLocalReplySend`.
        fileprivate let localReplySendID: UUID?
    }

    typealias BottomAnchorAction = @MainActor (BottomAnchorStep) -> Void
    typealias SenderGroupingLoader = ([String]) async -> [String: String]
    typealias AsyncAction = () async -> Void
    typealias LatestWindowLoader = (Int?) async -> Void
    typealias MessageVisibilityEnsurer = (NSManagedObjectID) async -> Bool
    typealias MessagePublicationCheck = (NSManagedObjectID) -> Bool
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
    /// Whether a row is already in the published window, so the post-send
    /// anchor can scroll without waiting for layout of a row it just loaded.
    private let isMessagePublished: MessagePublicationCheck
    private let markConversationAsReadIfNeeded: () -> Void
    private let markUnreadInboxMessagesAsReadIfNeeded: ([NSManagedObjectID]) -> Void
    private let initializeReplyingTo: (Message?) -> Void
    private let updateReplyingToIfNewSubject: (Message?) -> Void
    private let loadResolvedDisplayName: () -> Void
    private let prefetchSenderContacts: ([String]) -> Void
    private let cancelPrefetch: () -> Void
    private let loadSenderGroupingKeys: SenderGroupingLoader
    private let invalidateContactsCache: AsyncAction
    private let clearPersonCache: AsyncAction
    private let sleep: Sleep
    /// Sleeps for the reveal watchdog and the post-reveal audit, the two
    /// long timers. Kept apart from `sleep`, which paces the short re-probes:
    /// tests script those through `sleep` call by call, and a long timer
    /// sharing it would consume and reorder their calls.
    private let watchdogSleep: Sleep
    private let now: Now
    private let initialPresentationAnchor: InitialPresentationAnchor
    private let taskManager = ViewModelTaskManager()
    private var initialRevealState: InitialRevealState = .waitingForRows
    /// Wall-clock deadline for the pending initial-anchor pass; armed by
    /// `performInitialScroll`, cleared on completion. Consulted only while
    /// `initialRevealState` is `.pending`: by every offscreen geometry report,
    /// and by the pass's watchdog when no report has revealed the pass
    /// within `initialRevealWatchdogGrace` of it.
    private var initialAnchorRevealDeadline: TimeInterval?
    /// When `handleBottomAnchorGeometryUpdate` last ran, for the watchdog's
    /// log line: it tells a geometry signal that went quiet from one that
    /// kept reporting without revealing. Cleared when a pass starts and on
    /// disappear, so the line never cites a report from an earlier pass or
    /// appearance as this pass's last one.
    private var lastBottomAnchorGeometryReportAt: TimeInterval?
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
    /// A report during this reveal pass read as parked past the content end
    /// (`isTrackedContentParkedPastEnd`). Parked reports take the offscreen
    /// path and charge the retry budget, but they are measured geometry, not
    /// the untrustworthy signal the attempts-exhausted fallback otherwise
    /// assumes, so that fallback still arms bottom-follow after one.
    private var didObserveParkedPastEndDuringInitialPass = false
    /// When the current post-reveal follow was armed; bounds deadline sliding
    /// via `maximumPostRevealBottomFollowLifetime`.
    private var postRevealBottomFollowArmedAt: TimeInterval = 0
    private var isTrackedBottomAnchorVisible = false
    private var trackedContentMinY: CGFloat?
    private var trackedContentHeight: CGFloat?
    private var trackedViewportHeight: CGFloat?
    /// The reader's finger is on the transcript, as of the latest geometry
    /// update (the view re-reports geometry when its drag state changes).
    private var isTrackedUserScrollInteractionActive = false
    /// The scroll view itself is in a user-driven phase (tracking, interacting
    /// or decelerating). That covers what the transcript's 2pt drag gesture
    /// misses: trackpad and mouse-wheel scrolling, and a finger resting before
    /// it moves. Reported only where `ChatTranscriptOffsetShifter` observes
    /// scroll phases (iOS 26+); below that the drag flag stands alone.
    private var isTrackedScrollPhaseUserDriven = false
    private var consecutivePastContentEndCorrections = 0
    /// The shortest tracked content height seen parked during the current
    /// parked stretch: lowered when a correction fires and whenever a parked
    /// report restarts the count. A parked report with content shorter than
    /// this restarts the count of `maximumConsecutivePastContentEndCorrections`:
    /// the content changed under the correction, so it is not the stuck
    /// signal the bound exists for. The suspected case (not observed on
    /// device) is the lazy stack re-measuring rows a correction realized,
    /// with real heights under the estimates its scroll was planned with,
    /// which moves the content end up past a landing that was right when
    /// made. Any other new low (a spacer or bubble shrinking) restarts it
    /// too, which is harmless. The restart itself records the new low: a low
    /// that only ever shows up between corrections (reported, then
    /// re-estimated back up before the quiet beat fires) would otherwise read
    /// as new on every swing and restart the count forever. Each restart
    /// therefore needs a height below every height this stretch has seen,
    /// and `frame(minHeight:)` floors the content at the viewport height, so
    /// restarts are finite.
    private var smallestParkedContentHeight: CGFloat?
    /// The correction bound was reached and logged for the current parked
    /// stretch; logged once, since every later geometry report re-reaches it.
    private var didLogPastContentEndCorrectionBound = false
    private var postRevealBottomFollowState: PostRevealBottomFollowState = .inactive
    private var compensatedShiftHold: CompensatedShiftHold?
    private var hasCapturedInitialUnreadSnapshot = false
    private var isVisible = false
    private var userScrollInteractionRevision: UInt = 0
    private var optimisticReplyPublicationAttempts: [
        NSManagedObjectID: OptimisticReplyPublicationAttempt
    ] = [:]
    /// Local reply sends between `beginLocalReplySend` and
    /// `endLocalReplySend`. That spans the whole of `sendReply`, local MIME
    /// and attachment preflight included, so being in flight alone must not
    /// silence count-change scrolls (`isCountChangeOwnedByLocalReplySend`).
    private var localReplySendsInFlight = Set<UUID>()
    /// The subset of `localReplySendsInFlight` whose optimistic-publication
    /// anchor has not finished yet: the short stretch from the tap to the
    /// send's one scroll, during which that anchor owns every count-change
    /// scroll (it targets the bottom anchor, so it also covers anything else
    /// that lands meanwhile).
    private var localReplySendsAwaitingPublication = Set<UUID>()
    /// When the latest post-send animated scroll finishes. The admission step
    /// waits it out rather than snapping over a slide still in flight.
    private var postSendAnimatedScrollSettlesAt: TimeInterval = 0
    private var pendingAutoReadMessageIDsByEventID: [UUID: [NSManagedObjectID]] = [:]
    private var pendingAutoReadMessageIDsByLayoutID: [UUID: [NSManagedObjectID]] = [:]
    private var pendingAutoReadLayoutOrder: [UUID] = []

    init(
        scrollState: VirtualScrollState,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        initialPresentationAnchor: InitialPresentationAnchor,
        sleep: @escaping Sleep = ChatMessagesCoordinator.systemSleep,
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime },
        watchdogSleep: @escaping Sleep = ChatMessagesCoordinator.systemSleep
    ) {
        self.loadLatestWindowIfNeeded = { knownTotalCount in
            await scrollState.loadLatestWindowIfNeeded(knownTotalCount: knownTotalCount)
        }
        self.ensureVisibleMessage = { messageObjectID in
            await scrollState.ensureVisibleMessage(messageObjectID)
        }
        self.isMessagePublished = { messageObjectID in
            scrollState.visibleMessages.contains { $0.objectID == messageObjectID }
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
        self.prefetchSenderContacts = { senderEmails in
            viewModel.prefetchSenderContacts(senderEmails: senderEmails)
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
        self.watchdogSleep = watchdogSleep
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
        prefetchSenderContacts: @escaping ([String]) -> Void,
        cancelPrefetch: @escaping () -> Void,
        loadSenderGroupingKeys: @escaping SenderGroupingLoader,
        invalidateContactsCache: @escaping AsyncAction,
        clearPersonCache: @escaping AsyncAction,
        sleep: @escaping Sleep,
        now: @escaping Now = { ProcessInfo.processInfo.systemUptime },
        ensureVisibleMessage: @escaping MessageVisibilityEnsurer = { _ in true },
        isMessagePublished: @escaping MessagePublicationCheck = { _ in false },
        watchdogSleep: @escaping Sleep = ChatMessagesCoordinator.systemSleep
    ) {
        self.loadLatestWindowIfNeeded = loadLatestWindowIfNeeded
        self.ensureVisibleMessage = ensureVisibleMessage
        self.isMessagePublished = isMessagePublished
        self.markConversationAsReadIfNeeded = markConversationAsReadIfNeeded
        self.markUnreadInboxMessagesAsReadIfNeeded = markUnreadInboxMessagesAsReadIfNeeded
        self.initializeReplyingTo = initializeReplyingTo
        self.updateReplyingToIfNewSubject = updateReplyingToIfNewSubject
        self.loadResolvedDisplayName = loadResolvedDisplayName
        self.prefetchSenderContacts = prefetchSenderContacts
        self.cancelPrefetch = cancelPrefetch
        self.loadSenderGroupingKeys = loadSenderGroupingKeys
        self.invalidateContactsCache = invalidateContactsCache
        self.clearPersonCache = clearPersonCache
        self.sleep = sleep
        self.watchdogSleep = watchdogSleep
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
        compensatedShiftHold = nil
        isUserScrollTakeoverActive = false
        isTrackedUserScrollInteractionActive = false
        isTrackedScrollPhaseUserDriven = false
        consecutivePastContentEndCorrections = 0
        smallestParkedContentHeight = nil
        didLogPastContentEndCorrectionBound = false
        lastBottomAnchorGeometryReportAt = nil
        pendingAutoReadMessageIDsByEventID.removeAll()
        pendingAutoReadMessageIDsByLayoutID.removeAll()
        pendingAutoReadLayoutOrder.removeAll()
        optimisticReplyPublicationAttempts.values.forEach { $0.task.cancel() }
        optimisticReplyPublicationAttempts.removeAll()
        localReplySendsInFlight.removeAll()
        localReplySendsAwaitingPublication.removeAll()
        postSendAnimatedScrollSettlesAt = 0
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
    /// A transcript parked past its content end counts as offscreen for the reveal,
    /// and after the reveal it is scrolled back once the geometry is quiet
    /// (`isTrackedContentParkedPastEnd`).
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
        lastBottomAnchorGeometryReportAt = now()
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
        isTrackedUserScrollInteractionActive = isUserScrollInteractionActive
        // After every branch below, including the ones that complete the
        // reveal: a fallback reveal can land on a parked transcript.
        defer { updatePastContentEndCorrection(scrollAction: scrollAction) }
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

        if isHoldingForCompensatedShift {
            if didObserveGrowth {
                compensatedShiftHold?.didObserveGrowth = true
            }
            // The view is animating the transcript to the new bottom itself;
            // the spacer growth, and the lazy stack re-estimating heights as
            // the shift realizes rows, arrive here with the anchor briefly
            // offscreen. Answering them with the follow's unanimated jump
            // replaced the shift in the most common flow (open a chat, tap the
            // field within the follow window). The settle check re-anchors if
            // the shift did not end at the bottom.
            if isPostRevealBottomFollowArmed {
                return
            }
        }

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

        if isTrackedContentParkedPastEnd {
            didObserveParkedPastEndDuringInitialPass = true
        }

        // The 1pt anchor intersecting the viewport is not enough: parked far
        // enough past the content end it sits near the top of the viewport
        // with every bubble above it, and confirming that would reveal a blank
        // transcript until the reader's first touch (the suspected cause of
        // "the chat opens blank until I scroll"). Take the offscreen path and
        // scroll again instead.
        if isBottomAnchorVisible && !isTrackedContentParkedPastEnd {
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
                armsBottomFollowAfterFallback: hasObservedBottomAnchorGeometry,
                fallbackReason: "time limit reached"
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
                // The past-end correction lands a parked transcript on its end
                // right after this reveal; the follow then absorbs the async
                // bubble growth that comes next
                // (`didObserveParkedPastEndDuringInitialPass`).
                completeInitialReveal(
                    wasVisiblyConfirmed: false,
                    armsBottomFollowAfterFallback: didObserveParkedPastEndDuringInitialPass,
                    fallbackReason: "attempts exhausted"
                )
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

    /// Holds the post-reveal/post-send bottom follow while the view animates
    /// the transcript to compensate inset growth (`ChatBottomInsetPolicy`),
    /// then re-checks once the shift has settled.
    ///
    /// Without the hold, an armed follow saw the spacer's growth with the
    /// bottom anchor briefly offscreen and answered with an unanimated jump
    /// to the bottom over the smooth shift. Absorbing exactly the spacer's
    /// height was not enough: the lazy stack re-estimates row heights as the
    /// shift realizes rows (+2pt, then +136pt in the simulator), and each
    /// re-estimate read as layout growth.
    func handleCompensatedInsetGrowth(
        settlingIn settleDuration: TimeInterval,
        scrollAction: @escaping BottomAnchorAction
    ) {
        // Any hold still present has not had its settle check (the check
        // clears it), even if its time is up while the main actor is busy
        // with the end of the shift; merge rather than lose its correction.
        let currentHold = compensatedShiftHold
        let until = max(currentHold?.until ?? 0, now() + settleDuration)
        compensatedShiftHold = CompensatedShiftHold(
            until: until,
            startedAtBottom: (currentHold?.startedAtBottom ?? false) || isTrackedBottomAnchorVisible,
            didObserveGrowth: currentHold?.didObserveGrowth ?? false
        )
        if case .checkingAfterScroll(let deadline, _) = postRevealBottomFollowState {
            // A follow scroll's validation must not fire mid-shift either;
            // the settle check below takes over its job.
            taskManager.cancel(TaskKey.postRevealGeometryCheck)
            didObserveGrowthDuringPostRevealCheck = false
            postRevealBottomFollowState = .following(deadline: deadline)
        }

        let remaining = max(0, until - now())
        taskManager.run(TaskKey.compensatedShiftSettle) { [weak self, sleep] in
            await sleep(UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.finishCompensatedShiftHold(scrollAction: scrollAction)
        }
    }

    private var isHoldingForCompensatedShift: Bool {
        guard let compensatedShiftHold else { return false }
        return now() < compensatedShiftHold.until
    }

    private var isPostRevealBottomFollowArmed: Bool {
        if case .inactive = postRevealBottomFollowState {
            return false
        }
        return true
    }

    private var isCompensatedShiftFromBottomInFlight: Bool {
        isHoldingForCompensatedShift && compensatedShiftHold?.startedAtBottom == true
    }

    private func finishCompensatedShiftHold(scrollAction: @escaping BottomAnchorAction) {
        guard let hold = compensatedShiftHold else { return }
        compensatedShiftHold = nil
        // The shift's last geometry update can arrive while the hold still
        // stands, which defers the past-end correction; nothing else would
        // re-evaluate a transcript left parked at rest.
        defer { updatePastContentEndCorrection(scrollAction: scrollAction) }

        if isTrackedBottomAnchorVisible {
            // Ended at the bottom (including a shift from elsewhere, such as
            // the keyboard re-showing mid-return after a send).
            armCompensatedShiftSettleFollowIfIdle()
            return
        }

        if hold.startedAtBottom && hold.anchorsAtSettle {
            // A shift that started at the bottom must end there, follow or
            // not: the at-bottom keyboard skip relied on it, and an anchor
            // left offscreen also stopped the transcript following new
            // messages while the reader composed. Takeover does not block it:
            // the reader was at the bottom when the shift began, and any
            // scroll since cleared the hold. Animated, and held through its
            // animation with the follow armed, because the gap can be a whole
            // message that arrived mid-shift: an unanimated anchor, or a
            // follow answering the next re-estimate mid-animation, snapped
            // ~180pt in one frame in the simulator.
            scrollAction(
                BottomAnchorStep(
                    delay: 0,
                    animated: true,
                    logMessage: "ChatView compensated shift settle -> bottom anchor"
                )
            )
            armCompensatedShiftSettleFollowIfIdle()
            holdThroughSettleAnchor(scrollAction: scrollAction)
            return
        }

        // Growth during the shift that left the anchor offscreen at the end
        // (a bubble finishing its load mid-shift) is exactly what a live
        // follow exists to absorb.
        switch postRevealBottomFollowState {
        case .following(let deadline), .waitingForGrowth(let deadline):
            // Sliding an expired deadline would revive the follow, and a slide
            // past the follow's lifetime cap lands in the past.
            let slidDeadline = now() < deadline
                ? slidPostRevealFollowDeadline(extending: deadline)
                : deadline
            if hold.didObserveGrowth && now() < slidDeadline {
                requestPostRevealBottomScroll(
                    deadline: slidDeadline,
                    scrollAttempts: 1,
                    scrollAction: scrollAction
                )
            } else if now() >= slidDeadline {
                postRevealBottomFollowState = .inactive
            }
        case .checkingAfterScroll, .inactive:
            break
        }
    }

    private func holdThroughSettleAnchor(scrollAction: @escaping BottomAnchorAction) {
        let duration = UIConfig.scrollAnimationDuration + Self.settleAnchorHoldSlack
        compensatedShiftHold = CompensatedShiftHold(
            until: now() + duration,
            startedAtBottom: true,
            didObserveGrowth: false,
            anchorsAtSettle: false
        )
        taskManager.run(TaskKey.compensatedShiftSettle) { [weak self, sleep] in
            await sleep(UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.finishCompensatedShiftHold(scrollAction: scrollAction)
        }
    }

    private func armCompensatedShiftSettleFollowIfIdle() {
        let deadline = now() + Self.compensatedShiftSettleFollowGracePeriod
        switch postRevealBottomFollowState {
        case .following(let currentDeadline) where currentDeadline >= deadline,
             .waitingForGrowth(let currentDeadline) where currentDeadline >= deadline:
            // A live follow that already outlasts this one keeps its own
            // deadline and arm time.
            return
        case .checkingAfterScroll:
            // A follow scroll's validation is in flight and owns the anchor.
            return
        case .inactive, .following, .waitingForGrowth:
            // Arm fresh, including over an expired follow the view never
            // retired: keeping its old arm time capped every slide at a
            // lifetime that had already run out, so the follow was dead on
            // its first growth event.
            postRevealBottomFollowArmedAt = now()
            postRevealBottomFollowState = .following(deadline: deadline)
        }
    }

    /// The reader started moving the transcript by some means other than the
    /// transcript's drag gesture (trackpad, mouse wheel, an interactive
    /// dismissal's pan): a pending compensated-shift settle check must not
    /// pull them back to the bottom.
    func handleUserScrollPhaseBegan() {
        compensatedShiftHold = nil
        taskManager.cancel(TaskKey.compensatedShiftSettle)
    }

    /// The scroll view entered or left a user-driven scroll phase
    /// (`ChatTranscriptOffsetShifter`, iOS 26+). Kept apart from
    /// `handleUserScrollPhaseBegan`, which the drag path also calls: below iOS
    /// 26 nothing would report the phase ending. Leaving the phase re-runs the
    /// past-end check, because a transcript still parked when the reader lets
    /// go gets no further geometry update to re-arm it.
    func handleUserScrollPhaseChange(
        isUserDriven: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        isTrackedScrollPhaseUserDriven = isUserDriven
        updatePastContentEndCorrection(scrollAction: scrollAction)
    }

    /// Stops initial auto-anchoring and post-reveal bottom following once the user
    /// takes control of the scroll view.
    func handleUserScrollInteraction() {
        userScrollInteractionRevision &+= 1
        isUserScrollTakeoverActive = true
        taskManager.cancel(TaskKey.scrollTakeoverRelease)
        handleUserScrollPhaseBegan()
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
        taskManager.cancel(TaskKey.pastContentEndCorrection)
        taskManager.cancel(TaskKey.initialRevealWatchdog)

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
            if isCountChangeOwnedByLocalReplySend(lastMessage: lastMessage) {
                // The optimistic-publication anchor owns this send's scroll
                // (`handleReplyOptimisticMessagePersisted`). The count bump
                // from the optimistic save usually reaches here first;
                // scrolling too started a second, competing animation under
                // the same task key — whichever won, the motion differed send
                // to send. A message from sync arriving later in the send
                // (during attachment preflight) is not the send's own bump and
                // scrolls normally below.
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView count change during local send; deferring to post-send anchor messages=\(newCount)",
                    category: .ui
                )
            } else if isBottomAnchorVisible && !isUserScrollTakeoverActive {
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

    /// Whether a count increase is the user's own just-sent reply, whose
    /// scroll belongs to the optimistic-publication anchor.
    ///
    /// Only while a local send is in flight, and then in two cases:
    /// - its publication anchor has not finished: the bump is almost always
    ///   the send's own (a reload path can raise the count before the window
    ///   publishes the row, so `lastMessage` may still be the previous one),
    ///   and anything else that lands is covered by that anchor's scroll;
    /// - the newest message is a local optimistic send: the bump reached here
    ///   after the anchor had already scrolled.
    /// Anything else — another party's message arriving during a slow
    /// attachment preflight — keeps the animated count-change scroll: the
    /// post-send follow may have expired by then, and admission's correction
    /// is a single unanimated snap.
    private func isCountChangeOwnedByLocalReplySend(lastMessage: Message?) -> Bool {
        guard !localReplySendsInFlight.isEmpty else { return false }
        if !localReplySendsAwaitingPublication.isEmpty {
            return true
        }
        guard let lastMessage else { return false }
        return OutboundSendDeliveryState.localOptimisticMessageID(for: lastMessage) != nil
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

    /// - Parameter isInsetGrowthCompensated: whether the view shifts the
    ///   transcript by this change's inset growth in the same update
    ///   (`ChatBottomInsetPolicy.compensatesGrowth`). Deliberately no
    ///   default, like `hasBottomAnchorGeometry`: every caller must decide
    ///   it. (Tests use a defaulted overload in their own target.)
    func handleKeyboardHeightChange(
        oldHeight: CGFloat,
        newHeight: CGFloat,
        messageCount: Int,
        isInitialWindowLoaded: Bool,
        isInsetGrowthCompensated: Bool,
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
        // Takeover still suppresses the scroll-to-bottom (never yank a reader
        // out of history). Keeping what they were reading above the keyboard
        // is the view's inset-growth shift, which runs regardless of takeover.
        guard !isUserScrollTakeoverActive else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping keyboard bottom anchor during user scroll takeover compensated=\(isInsetGrowthCompensated)",
                category: .ui
            )
            return
        }
        // At the bottom the view's shift is planned to land on the new bottom
        // (and its settle check corrects a short landing); a scroll-to-bottom
        // here would start a second animated scroll toward the same point
        // ~50ms into it. Off the bottom without a takeover
        // (a stranded reveal, late bubble growth after the follow expired) the
        // scroll-to-bottom still runs, so replying keeps showing the latest
        // message as it did before the shift existed.
        // Mid-shift the unanimated spacer growth has already pushed the anchor
        // offscreen, so a keyboard publishing its height in two steps also
        // counts a shift that started at the bottom.
        if isInsetGrowthCompensated && newHeight > oldHeight &&
            (isTrackedBottomAnchorVisible || isCompensatedShiftFromBottomInFlight) {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping keyboard bottom anchor: inset growth compensated at the bottom",
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
            userScrollInteractionRevision: userScrollInteractionRevision,
            localReplySendID: nil
        )
    }

    /// `capturePostSendAnchorIntent` for a reply this chat is about to send,
    /// which also registers the send as in flight: until `endLocalReplySend`,
    /// the send's own count bump defers to the post-send anchor
    /// (`isCountChangeOwnedByLocalReplySend`). The view calls
    /// it before `sendReply` (whose optimistic save bumps the count) and must
    /// pair it with `endLocalReplySend` on every exit; disappearing clears it.
    func beginLocalReplySend() -> PostSendAnchorIntent {
        let localReplySendID = UUID()
        localReplySendsInFlight.insert(localReplySendID)
        localReplySendsAwaitingPublication.insert(localReplySendID)
        return PostSendAnchorIntent(
            userScrollInteractionRevision: userScrollInteractionRevision,
            localReplySendID: localReplySendID
        )
    }

    /// Ends a send `beginLocalReplySend` registered, whatever its outcome.
    func endLocalReplySend(_ anchorIntent: PostSendAnchorIntent) {
        guard let localReplySendID = anchorIntent.localReplySendID else { return }
        localReplySendsInFlight.remove(localReplySendID)
        localReplySendsAwaitingPublication.remove(localReplySendID)
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
        // The tail-append fast path (`VirtualScrollState+TailAppend`) has
        // usually published the row in the optimistic save's own turn. That is
        // not proof SwiftUI has laid it out: the hops between here and the
        // scroll are main-actor jobs, which can drain before the run-loop pass
        // that commits the update, and a scroll resolved against the old
        // layout slides to the old bottom, then the follow snaps it the rest
        // of the way. Such a row waits one frame
        // (`UIConfig.postSendLayoutCommitDelay`), not the 50ms a row this
        // task still has to load waits.
        let wasAlreadyPublished = isMessagePublished(targetMessageID)
        let localReplySendID = anchorIntent.localReplySendID
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
        // Admission consumes this task even after it completes so it never
        // mistakes a successful publication for a reason to reload latest.
        taskManager.run(
            TaskKey.optimisticReplyPublication(targetMessageID)
        ) { [weak self, publicationTask] in
            let didPublishTarget = await publicationTask.value
            guard let self else { return }
            // On every exit, whether or not it scrolls: from here on the send's
            // own count bump is recognised by its optimistic row
            // (`isCountChangeOwnedByLocalReplySend`), and nothing else may be
            // silenced for the rest of a long preflight.
            defer {
                if let localReplySendID {
                    self.localReplySendsAwaitingPublication.remove(localReplySendID)
                }
            }
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

            // The send's one scroll: animated, one frame after a row that was
            // already in the window (only a row this task had to load waits
            // `contentChangeScrollDelay` for its layout). There is no
            // stabilization step any more: the follow armed below corrects
            // growth the slide could not see (a bubble resolving its content
            // late), and a second, unanimated scroll 200ms later only snapped
            // a transcript that was already at the bottom.
            self.scrollToBottom(
                messageCount: max(1, max(messageCount, totalMessageCount)),
                delay: wasAlreadyPublished
                    ? UIConfig.postSendLayoutCommitDelay
                    : UIConfig.contentChangeScrollDelay,
                reloadLatestWindow: false
            ) { [weak self] step in
                if step.animated, let self {
                    self.postSendAnimatedScrollSettlesAt =
                        self.now() + UIConfig.scrollAnimationDuration
                }
                scrollAction(step)
            }
            // Keep following bounded layout growth while local preflight is
            // still running. Admission refreshes this grace period once more.
            if self.isReadyToShow {
                self.armPostSendBottomFollow()
            }
        }
    }

    /// Reconfirms exact-row publication after local preflight reaches the
    /// durable Gmail-admission boundary, then performs one non-animated
    /// correction for layout or sync-echo growth that happened during preflight
    /// — only when the bottom anchor is not already on screen. At the bottom
    /// the correction had nothing to do, and when admission came within ~50ms
    /// of publication it landed mid-slide and snapped the rest of it.
    func handleReplySendAdmitted(
        targetMessageID: NSManagedObjectID,
        anchorIntent: PostSendAnchorIntent,
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        let effectiveMessageCount = max(messageCount, totalMessageCount)
        let initialPublicationAttempt = optimisticReplyPublicationAttempts[
            targetMessageID
        ]
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
            defer {
                if let initialPublicationAttempt {
                    self.clearOptimisticReplyPublicationAttempt(
                        for: targetMessageID,
                        id: initialPublicationAttempt.id
                    )
                }
            }
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
            if let initialPublicationAttempt,
               await initialPublicationAttempt.task.value {
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
            // Let a post-send slide still in flight finish first: its anchor
            // reads offscreen until it lands, which must not buy a snap.
            let remainingSlide = self.postSendAnimatedScrollSettlesAt - self.now()
            if remainingSlide > 0 {
                await sleep(UInt64(remainingSlide * 1_000_000_000))
                guard !Task.isCancelled, self.isVisible,
                      self.userScrollInteractionRevision ==
                        anchorIntent.userScrollInteractionRevision else {
                    return
                }
            }
            if self.isTrackedBottomAnchorVisible {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView reply admission found bottom anchor visible; no stabilization scroll",
                    category: .ui
                )
            } else {
                scrollAction(step)
            }
            self.armPostSendBottomFollow()
        }
    }

    func handleReplySendFailed(targetMessageID: NSManagedObjectID) {
        optimisticReplyPublicationAttempts[targetMessageID]?.task.cancel()
        optimisticReplyPublicationAttempts.removeValue(forKey: targetMessageID)
        taskManager.cancel(TaskKey.optimisticReplyPublication(targetMessageID))
        taskManager.cancel(TaskKey.replyAdmissionStabilization(targetMessageID))
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

#if DEBUG
    /// Lets tests join the scheduled bottom-anchor scroll (a count change's or
    /// a send's) before asserting that no other scroll landed, instead of
    /// waiting a scheduler-dependent number of yields.
    func waitForBottomAnchorScrollCompletion() async {
        await taskManager.waitForCompletion(of: TaskKey.bottomAnchor)
    }

    /// Lets tests join a send's optimistic-publication anchor, including the
    /// exits that skip its scroll.
    func waitForOptimisticReplyPublicationCompletion(
        targetMessageID: NSManagedObjectID
    ) async {
        await taskManager.waitForCompletion(
            of: TaskKey.optimisticReplyPublication(targetMessageID)
        )
    }

    /// Lets tests join a send's admission step before asserting it did not
    /// scroll.
    func waitForReplyAdmissionCompletion(targetMessageID: NSManagedObjectID) async {
        await taskManager.waitForCompletion(
            of: TaskKey.replyAdmissionStabilization(targetMessageID)
        )
    }
#endif

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
        let senderEmails = recentMessages.compactMap(\.senderEmail)

        prefetchSenderContacts(senderEmails)
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
            // This runs on every displayed-ID change, a send and its echo
            // included, and usually resolves the same keys. Assigning anyway
            // published objectWillChange, which the chat session forwards, so
            // every realized bubble re-evaluated its body for nothing.
            if self.senderGroupingKeysByEmail != groupingKeys {
                self.senderGroupingKeysByEmail = groupingKeys
            }
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

        performInitialScroll(
            messageCount: anchorMessageCount,
            reason: reason,
            scrollAction: scrollAction
        )
    }

    private func performInitialScroll(
        messageCount: Int,
        reason: String,
        scrollAction: @escaping BottomAnchorAction
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
        let revealDeadline = now() + Self.initialAnchorRevealTimeLimit
        initialAnchorRevealDeadline = revealDeadline
        hasObservedBottomAnchorGeometry = false
        lastBottomAnchorGeometryReportAt = nil
        didObserveGrowthDuringInitialRecheck = false
        didObserveParkedPastEndDuringInitialPass = false
        initialAnchorGeometryCheckID = UUID()
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView initial anchor awaiting layout reason=\(reason) messages=\(messageCount)",
            category: .ui
        )
        armInitialRevealWatchdog(deadline: revealDeadline, scrollAction: scrollAction)
        if messageCount > 1 {
            taskManager.run(TaskKey.initialBottomAnchor) { [loadLatestWindowIfNeeded] in
                await loadLatestWindowIfNeeded(nil)
            }
        }
    }

    /// Reveals a pass still pending `initialRevealWatchdogGrace` after its
    /// time limit, when no geometry report has evaluated the deadline.
    ///
    /// The deadline is otherwise read only inside
    /// `handleBottomAnchorGeometryUpdate`, which the view calls from geometry
    /// and `initialAnchorGeometryCheckID` changes. Every pending phase keeps
    /// those coming (each re-probe task ends in a check-ID bump), so a pass
    /// still pending after the grace means the reports stopped, as when
    /// SwiftUI drops a delivery. Nothing in this repo is known to cause that,
    /// but without the watchdog the transcript would then stay hidden behind
    /// the spinner until the reader drags it out. Waking before the deadline
    /// (`now()` is `systemUptime`, which stops while the device sleeps; the
    /// sleep's clock need not) re-arms once for the time left, then leaves
    /// anything still short to the next geometry report rather than
    /// re-sleeping in a loop a test's immediate sleep would spin.
    private func armInitialRevealWatchdog(
        deadline: TimeInterval,
        scrollAction: @escaping BottomAnchorAction
    ) {
        let waitNanoseconds = UInt64(
            (Self.initialAnchorRevealTimeLimit + Self.initialRevealWatchdogGrace) * 1_000_000_000
        )
        taskManager.run(TaskKey.initialRevealWatchdog) { [weak self, watchdogSleep] in
            await watchdogSleep(waitNanoseconds)
            guard !Task.isCancelled, let self else { return }
            let remaining = deadline - self.now()
            if remaining > 0 {
                await watchdogSleep(UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled,
                  case .pending = self.initialRevealState,
                  // A restarted pass armed its own deadline and watchdog.
                  self.initialAnchorRevealDeadline == deadline,
                  self.now() >= deadline else {
                return
            }
            let lastReport = self.lastBottomAnchorGeometryReportAt.map {
                String(format: "%.2fs ago", self.now() - $0)
            } ?? "never"
            self.completeInitialReveal(
                wasVisiblyConfirmed: false,
                armsBottomFollowAfterFallback: self.hasObservedBottomAnchorGeometry,
                fallbackReason: "time limit passed with no geometry report revealing it (watchdog; last report \(lastReport))"
            )
            // The geometry handler's deferred check never ran for this reveal.
            self.updatePastContentEndCorrection(scrollAction: scrollAction)
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
                  self.isTrackedBottomAnchorVisible,
                  // Defensive: a parked report normally reaches the pending
                  // branch, which leaves .confirmingVisibility before this
                  // wakes. This covers one that bypasses it (an armed follow
                  // returning early during a restarted pass).
                  !self.isTrackedContentParkedPastEnd else {
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

    /// The transcript is scrolled past its content end: the content's bottom
    /// edge sits above the viewport's bottom edge, so the space between them
    /// is empty. A transcript shorter than the viewport never reads as parked,
    /// because the view floors the content to the viewport height.
    ///
    /// Why it is tracked ("the chat opens blank until I scroll"). This is the
    /// most plausible mechanism for that report, not an observed one: the
    /// device-side cause was never reproduced. The scroll view does not clamp
    /// an offset past the end while at rest (simulator probe: an offset forced
    /// 400pt past the end stayed there, and `proxy.scrollTo(bottomID, anchor:
    /// .bottom)` from it landed exactly on the end). Before this check, the
    /// reveal gate and the bottom follow read only whether the 1pt anchor
    /// intersects the viewport. Parked `d` points past the end, the anchor
    /// sits `d` points above the viewport bottom, and the newest bubble sits
    /// the trailing spacer (the composer's height) plus 17pt above the anchor.
    /// From `d` of about viewport height - spacer - 17pt up to a full
    /// viewport, the anchor still intersects while every bubble is above the
    /// top edge: a blank transcript the gate confirmed. Parks of a viewport or
    /// more hide the anchor too, and after the reveal nothing corrected those
    /// either, because the follow answers only growth. The ordinary content
    /// shrinks tried in the simulator (tail rows collapsing, window slides and
    /// replacements) all clamped. So this checks the resulting geometry rather
    /// than any one cause.
    private var isTrackedContentParkedPastEnd: Bool {
        guard let trackedContentMinY,
              let trackedContentHeight,
              let trackedViewportHeight,
              trackedContentHeight > 0,
              trackedViewportHeight > 0 else {
            return false
        }
        return trackedContentMinY + trackedContentHeight <
            trackedViewportHeight - Self.pastContentEndTolerance
    }

    /// Scrolls a revealed transcript parked past its content end back to it,
    /// as the reader's next touch would (`isTrackedContentParkedPastEnd`).
    ///
    /// Every geometry update re-arms the check, so it fires only after the
    /// geometry has been quiet for a beat. A rubber-band bounce, an animated
    /// shift, or a spacer animating with the keyboard settles first and is
    /// never fought. It is not a jump into history, so user-scroll takeover
    /// does not block it. A finger on the transcript does, and so does a
    /// user-driven scroll phase (`isTrackedScrollPhaseUserDriven`).
    private func updatePastContentEndCorrection(scrollAction: @escaping BottomAnchorAction) {
        guard isTrackedContentParkedPastEnd else {
            consecutivePastContentEndCorrections = 0
            smallestParkedContentHeight = nil
            didLogPastContentEndCorrectionBound = false
            taskManager.cancel(TaskKey.pastContentEndCorrection)
            return
        }
        guard canCorrectPastContentEnd else {
            taskManager.cancel(TaskKey.pastContentEndCorrection)
            return
        }
        // A correction lands on the content end, and the next report reads
        // in range and resets the count. If the landing realizes rows shorter
        // than estimated (suspected, not observed), the same layout pass
        // moves the end up again and that report already reads parked; the
        // count alone would then run out while each correction still made
        // progress (`smallestParkedContentHeight`).
        if let smallestParkedContentHeight,
           let trackedContentHeight,
           trackedContentHeight < smallestParkedContentHeight - Self.geometryChangeTolerance {
            consecutivePastContentEndCorrections = 0
            didLogPastContentEndCorrectionBound = false
            // The restart records the low itself; see
            // `smallestParkedContentHeight` for why a low the correction
            // never fires at must not stay "new".
            self.smallestParkedContentHeight = trackedContentHeight
        }
        guard consecutivePastContentEndCorrections <
                Self.maximumConsecutivePastContentEndCorrections else {
            if !didLogPastContentEndCorrectionBound {
                didLogPastContentEndCorrectionBound = true
                // Always logged; see `completeInitialReveal`.
                Log.warning(
                    "ChatView parked past content end; correction bound reached; \(trackedGeometryDescription)",
                    category: .ui
                )
            }
            return
        }
        let maximumCorrections = Self.maximumConsecutivePastContentEndCorrections
        taskManager.run(TaskKey.pastContentEndCorrection) { [weak self, sleep] in
            await sleep(UInt64(UIConfig.initialScrollDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.isTrackedContentParkedPastEnd,
                  self.canCorrectPastContentEnd,
                  // A compensated shift owns the scroll until it settles; its
                  // settle re-runs this check (`finishCompensatedShiftHold`).
                  !self.isHoldingForCompensatedShift else {
                return
            }
            self.consecutivePastContentEndCorrections += 1
            if let trackedContentHeight = self.trackedContentHeight {
                self.smallestParkedContentHeight = min(
                    self.smallestParkedContentHeight ?? trackedContentHeight,
                    trackedContentHeight
                )
            }
            // Always logged; see `completeInitialReveal`.
            Log.warning(
                "ChatView parked past content end; correcting (\(self.consecutivePastContentEndCorrections) of \(maximumCorrections)); \(self.trackedGeometryDescription)",
                category: .ui
            )
            scrollAction(
                BottomAnchorStep(
                    delay: 0,
                    animated: false,
                    logMessage: "ChatView parked past content end -> bottom anchor"
                )
            )
        }
    }

    /// Before the reveal the pending reveal machine owns scrolling (and
    /// treats a parked transcript as offscreen).
    private var canCorrectPastContentEnd: Bool {
        guard case .ready = initialRevealState else { return false }
        return isVisible &&
            !isTrackedUserScrollInteractionActive &&
            !isTrackedScrollPhaseUserDriven
    }

    private var trackedGeometryDescription: String {
        func describe(_ value: CGFloat?) -> String {
            value.map { String(format: "%.1f", $0) } ?? "nil"
        }
        let contentMaxY = trackedContentMinY.flatMap { minY in
            trackedContentHeight.map { minY + $0 }
        }
        return "anchorVisible=\(isTrackedBottomAnchorVisible) contentMaxY=\(describe(contentMaxY)) contentHeight=\(describe(trackedContentHeight)) viewportHeight=\(describe(trackedViewportHeight))"
    }

    /// - Parameter fallbackReason: why an unconfirmed reveal happened, for its
    ///   log line.
    private func completeInitialReveal(
        wasVisiblyConfirmed: Bool,
        armsBottomFollowAfterFallback: Bool = false,
        fallbackReason: String? = nil
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
        didObserveParkedPastEndDuringInitialPass = false
        taskManager.cancel(TaskKey.initialRevealWatchdog)
        isReadyToShow = true
        if wasVisiblyConfirmed {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor remained visible through stabilization; \(trackedGeometryDescription)",
                category: .ui
            )
        } else {
            let reason = fallbackReason ?? "fallback"
            let logMessage = armsBottomFollowAfterFallback
                ? "ChatView initial anchor \(reason); revealing with bottom follow"
                : "ChatView initial anchor \(reason); revealing fallback"
            // Always logged, not `Log.diagnostic`: the chat-view diagnostics
            // exist only in Debug builds launched from Xcode with
            // ESC_LOG_DIAGNOSTICS set, and the intermittent "chat opens blank
            // until I scroll" report never reproduced under them. A warning
            // persists in the device log, so the next blank open can be read
            // back afterwards. Geometry only; no message content.
            Log.warning("\(logMessage); \(trackedGeometryDescription)", category: .ui)
        }
        schedulePostRevealAudit()
    }

    /// Looks at the transcript once more `postRevealAuditDelay` after an
    /// automatic reveal and logs a warning if it still sits parked past its
    /// content end (`isTrackedContentParkedPastEnd`) while the correction
    /// could have run, with the correction's state. By then the past-end
    /// correction should have landed it, so the line means it was used up or
    /// its scroll did not land. A park the correction is deliberately holding
    /// for (a finger or user-driven scroll phase on the transcript, or a
    /// compensated shift still settling) is expected and logged at info only,
    /// so a reader rubber-banding the end does not write the warning the
    /// blank-open report is read by. Diagnostics only: it changes no state.
    ///
    /// Together with the reveal and correction warnings, it splits the next
    /// device report of a blank open: a warning names a scroll position
    /// problem. No warning at all means the last geometry the coordinator
    /// received read as correct while nothing showed, which points at
    /// drawing rather than position, unless geometry deliveries stopped
    /// (then the tracked values are stale; the watchdog's line says when the
    /// last report came).
    private func schedulePostRevealAudit() {
        let delay = Self.postRevealAuditDelay
        taskManager.run(TaskKey.postRevealAudit) { [weak self, watchdogSleep] in
            await watchdogSleep(UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  case .ready = self.initialRevealState,
                  self.isVisible,
                  self.isTrackedContentParkedPastEnd else {
                return
            }
            let message = "ChatView still parked past content end \(delay)s after reveal; corrections=\(self.consecutivePastContentEndCorrections) takeover=\(self.isUserScrollTakeoverActive) fingerDown=\(self.isTrackedUserScrollInteractionActive) scrollPhaseUserDriven=\(self.isTrackedScrollPhaseUserDriven) shiftHold=\(self.isHoldingForCompensatedShift); \(self.trackedGeometryDescription)"
            if self.canCorrectPastContentEnd && !self.isHoldingForCompensatedShift {
                Log.warning(message, category: .ui)
            } else {
                Log.info(message, category: .ui)
            }
        }
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
