import SwiftUI
import CoreData
import Combine

// `NSManagedObjectID` is the cross-context token Core Data intends us to pass
// between queues, so this payload is safe to move across task boundaries.
struct VirtualScrollMessagePage: @unchecked Sendable {
    let messageIDs: [NSManagedObjectID]
    let totalCount: Int
    let fetchErrorDescription: String?

    init(
        messageIDs: [NSManagedObjectID],
        totalCount: Int,
        fetchErrorDescription: String? = nil
    ) {
        self.messageIDs = messageIDs
        self.totalCount = totalCount
        self.fetchErrorDescription = fetchErrorDescription
    }
}

struct VirtualScrollInsertedMessageEvent: Equatable {
    let id: UUID
    let messageIDs: [NSManagedObjectID]
}

struct VirtualScrollInsertedMessageRefresh: Equatable {
    let eventID: UUID
    let layoutID: UUID
    let messageIDsInLatestWindow: [NSManagedObjectID]
}

// MARK: - Virtual Scroll State

/// Windowed data source for the chat transcript. Split as Type+Facet files;
/// this base file owns the stored state, the `WindowLoadLifecycle` machine
/// and its transition terminals, the position/hold API, and
/// `cleanup()`/`resume()`. The facets:
/// - `VirtualScrollState+InitialLoad.swift` — first-window materialization,
///   retry, and the initial publish.
/// - `VirtualScrollState+WindowLoading.swift` — latest-window follow,
///   explicit-message visibility, generic window loads, and preload
///   pagination.
/// - `VirtualScrollState+Reconciliation.swift` — dataset reconciliation
///   scheduling, post-sync validation, and clamped historical reloads.
/// - `VirtualScrollState+ChangeObservation.swift` — viewContext change
///   observation and inserted/refreshed/deleted message classification.
/// - `VirtualScrollState+RowCache.swift` — row-model cache, absolute-index
///   resolution, and the static page loaders.
/// Members shared across facets are internal (Swift `private` is
/// file-scoped); `private` marks state used only in this file.
@MainActor
final class VirtualScrollState: ObservableObject {
    enum InitialLoadPhase: Equatable {
        case loading
        case loaded
        case empty
        case failed
    }

    enum InitialWindowPosition {
        case beginning
        case end
    }

    typealias MessagePageLoader = (
        _ conversationId: String,
        _ range: Range<Int>,
        _ context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage

    struct InitialWindowLoad {
        let range: Range<Int>
        let page: VirtualScrollMessagePage
        let messages: [ChatMessageRowModel]
    }

    struct LoadedWindowBounds {
        let startIndex: Int
        let totalCount: Int
        let generation: UInt
    }

    struct UncachedRefreshAssessment {
        var orderedDatasetDidChange = false
        var needsCountReconciliation = false
    }

    enum WindowLoadIntent: Equatable {
        case latest(requiredFollowIntentRevision: UInt?)
        case range(Range<Int>)
    }

    /// Lifecycle of the single in-flight load. One value instead of the
    /// previously independent `isLoadingMore` flag and
    /// `currentWindowLoadIntent` optional, whose illegal combination — not
    /// loading, intent still set — silently wedged every automatic
    /// reconciliation until the chat closed (the `finishWindowLoadFailure`
    /// bug pinned by
    /// `testWindowLoadFailure_doesNotWedgeAutomaticReconciliation`). The enum
    /// makes that state unrepresentable: an intent exists only while its load
    /// does. `windowLoadGeneration` stays a separate monotonic token because
    /// stale completions compare captured generations after the lifecycle has
    /// already moved on.
    enum WindowLoadLifecycle: Equatable {
        /// No load in flight; automatic reconciliation may run.
        case idle
        /// `loadInitialMessages` is materializing the first window. There is
        /// no window intent to replay, and reconciliation must wait.
        case loadingInitialWindow
        /// A window load owns the user's current scroll intent.
        case loadingWindow(intent: WindowLoadIntent)
    }

    enum InitialLoadAttemptFailure: Error {
        case cancelled
        case pageFetchFailed(description: String, reportedTotalCount: Int?)
        case rowFetchFailed(description: String, reportedTotalCount: Int)
        case datasetChanged(reportedTotalCount: Int?)
        case inconsistentWindow(
            totalCount: Int,
            requestedIDCount: Int,
            resolvedRowCount: Int
        )

        var reportedTotalCount: Int? {
            switch self {
            case .cancelled:
                return nil
            case .pageFetchFailed(_, let reportedTotalCount):
                return reportedTotalCount
            case .rowFetchFailed(_, let reportedTotalCount):
                return reportedTotalCount
            case .datasetChanged(let reportedTotalCount):
                return reportedTotalCount
            case .inconsistentWindow(let totalCount, _, _):
                return totalCount
            }
        }

        var userFacingReason: String {
            "Messages couldn’t be loaded. Please try again."
        }

        var diagnosticDescription: String {
            switch self {
            case .cancelled:
                return "cancelled"
            case .pageFetchFailed(let description, let reportedTotalCount):
                return "page fetch failed total=\(reportedTotalCount.map(String.init) ?? "unknown") error=\(description)"
            case .rowFetchFailed(let description, let reportedTotalCount):
                return "row fetch failed total=\(reportedTotalCount) error=\(description)"
            case .datasetChanged(let reportedTotalCount):
                return "message dataset changed total=\(reportedTotalCount.map(String.init) ?? "unknown")"
            case .inconsistentWindow(
                let totalCount,
                let requestedIDCount,
                let resolvedRowCount
            ):
                return "inconsistent window total=\(totalCount) ids=\(requestedIDCount) rows=\(resolvedRowCount)"
            }
        }
    }

    @Published var visibleMessages: [ChatMessageRowModel] = []
    @Published var totalMessageCount = 0
    var scrollPosition: Int = 0
    var isLoadingMore: Bool { windowLoadLifecycle != .idle }
    @Published var initialLoadPhase: InitialLoadPhase = .loading
    @Published var initialLoadFailureReason: String?
    @Published var latestWindowLayoutID = UUID()

    var isInitialLoadComplete: Bool {
        initialLoadPhase == .loaded || initialLoadPhase == .empty
    }

    let insertedVisibleMessageEvents = PassthroughSubject<VirtualScrollInsertedMessageEvent, Never>()
    let refreshedInsertedMessageEvents = PassthroughSubject<VirtualScrollInsertedMessageRefresh, Never>()

    let configuration: VirtualScrollConfiguration
    let initialWindowPosition: InitialWindowPosition
    var messageWindow: MessageWindow?
    let conversationId: String
    let viewContext: NSManagedObjectContext
    let makeBackgroundContext: () -> NSManagedObjectContext
    let pageLoader: MessagePageLoader

    // Cache only lightweight row snapshots for the current window. Background
    // contexts fetch IDs, and the UI never stores `Message` instances here.
    var resolvedRowsByID: [NSManagedObjectID: ChatMessageRowModel] = [:]
    var resolvedRowsByAbsoluteIndex: [Int: ChatMessageRowModel] = [:]
    var viewContextChangesCancellable: AnyCancellable?
    var syncCompletedCancellable: AnyCancellable?
    var cachedConversationObjectID: NSManagedObjectID?
    var pendingInsertedMessageEvents: [VirtualScrollInsertedMessageEvent] = []
    private var followsLatestInsertions = true
    var followIntentRevision: UInt = 0
    /// While the coordinator's initial bottom-anchor pass is still positioning
    /// the hidden transcript, row `onAppear` events describe the top-anchored
    /// pre-reveal layout, not user scrolling. Honoring them moved
    /// `scrollPosition` off the parked window head (the ±2 movement guard in
    /// `markIndexVisible` only covers head..head+2, while `bufferSize` and
    /// `preloadThreshold` reach further), which requested uncovered older
    /// ranges and previous-page preloads that prepended rows and shifted the
    /// viewport mid-anchor — the same cascade the head-parking in
    /// `loadLatestWindow` guards against. Armed by `publishInitialWindow` for
    /// end-anchored windows; the view releases it via `endInitialAnchorHold()`
    /// once the coordinator reveals the transcript.
    var isInitialAnchorHoldActive = false
    /// While the chat view animates a programmatic inset shift (the transcript
    /// scrolling with the keyboard, `ChatTranscriptOffsetShifter`), row
    /// `onAppear` positions are held and replayed once it settles. Honoring
    /// them mid-animation replaced the window as rows appeared, and a
    /// replacement drops rows above the viewport; an in-flight programmatic
    /// scroll does not re-anchor on that, so the newly exposed rows slid the
    /// window again and one keyboard show walked a far-up reader ~24 messages
    /// forward (simulator: 9 of 15 runs). See `holdWindowForProgrammaticScroll`.
    var isProgrammaticScrollHoldActive = false
    var heldVisibleIndex: Int?
    /// A held position whose replay would add rows above the window, kept
    /// until the reader next scrolls (`handleUserScrollInteractionBegan`).
    /// Prepending at rest is not re-anchored: after a keyboard-hide shift it
    /// moved the content under a reader near the window top by a row or more.
    var deferredLeadingReplayIndex: Int?
    let programmaticScrollHoldTaskKey = "programmaticScrollHold"

    // Task tracking to prevent orphaned tasks during rapid scrolling
    let taskManager = ViewModelTaskManager()
    let datasetReconcileTaskKey = "reconcileWindowAfterDatasetMutation"
    let postSyncValidationTaskKey = "validateWindowAfterSync"
    let unclassifiedRefreshCountTaskKey = "reconcileUnclassifiedRefreshCount"
    let maximumAutomaticInitialLoadRetryCount = 1
    let maximumAutomaticPostSyncValidationRetryCount = 1
    let maximumExplicitMessageVisibilityRetryCount = 1
    let initialLoadRetryDelayNanoseconds: UInt64 = 100_000_000
    var initialLoadSignpostInterval: ChatViewPerformanceSignposts.Interval?
    var windowLoadGeneration: UInt = 0
    var messageDatasetGeneration: UInt = 0
    var postSyncValidationRetryCount = 0
    var needsDatasetReconciliationAfterCurrentLoad = false
    var needsUnclassifiedRefreshCountReconciliation = false
    var needsPostSyncDatasetReconciliation = false
    var windowLoadLifecycle: WindowLoadLifecycle = .idle
    var currentWindowLoadIntent: WindowLoadIntent? {
        if case .loadingWindow(let intent) = windowLoadLifecycle { return intent }
        return nil
    }

    init(
        conversationId: String,
        configuration: VirtualScrollConfiguration = .default,
        initialWindowPosition: InitialWindowPosition = .beginning
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.initialWindowPosition = initialWindowPosition
        self.viewContext = CoreDataStack.shared.viewContext
        self.makeBackgroundContext = { CoreDataStack.shared.newBackgroundContext() }
        self.pageLoader = VirtualScrollState.loadMessagePage
        startObservingViewContextChanges()
        loadInitialMessages()
    }

    init(
        conversationId: String,
        configuration: VirtualScrollConfiguration = .default,
        initialWindowPosition: InitialWindowPosition = .beginning,
        viewContext: NSManagedObjectContext,
        makeBackgroundContext: @escaping () -> NSManagedObjectContext,
        pageLoader: @escaping MessagePageLoader = VirtualScrollState.loadMessagePage,
        autoLoad: Bool = true
    ) {
        self.conversationId = conversationId
        self.configuration = configuration
        self.initialWindowPosition = initialWindowPosition
        self.viewContext = viewContext
        self.makeBackgroundContext = makeBackgroundContext
        self.pageLoader = pageLoader
        startObservingViewContextChanges()

        if autoLoad {
            loadInitialMessages()
        }
    }

    /// Notifies the scroll state that a message at the given index is now visible.
    /// Called from onAppear for each message in the LazyVStack.
    func markIndexVisible(_ index: Int) {
        // Pre-reveal onAppear reflects the hidden top-anchored layout, not
        // user intent; see `isInitialAnchorHoldActive`.
        guard !isInitialAnchorHoldActive else { return }
        if isProgrammaticScrollHoldActive {
            heldVisibleIndex = index
            return
        }

        // Skip small position changes to avoid excessive updates during scroll
        // This prevents 10+ calls per scroll when each visible message fires onAppear
        guard abs(index - scrollPosition) > 2 else { return }

        // A position the reader scrolled to supersedes a deferred replay. Only
        // one that moves the window: a nearby onAppear that the guard above
        // ignores must not drop the replay without loading anything.
        deferredLeadingReplayIndex = nil

        scrollPosition = index
        updateVisibleMessages()
        preloadIfNeeded()
    }

    /// Holds `markIndexVisible` for `duration` while the view animates a
    /// programmatic inset shift, then replays the latest held position
    /// (`isProgrammaticScrollHoldActive`). Re-arming restarts the hold with the
    /// new duration: a later shift supersedes the earlier scroll.
    func holdWindowForProgrammaticScroll(settlingIn duration: TimeInterval) {
        isProgrammaticScrollHoldActive = true
        deferredLeadingReplayIndex = nil
        taskManager.run(programmaticScrollHoldTaskKey) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.releaseProgrammaticScrollHold(isUserScrolling: false)
        }
    }

    /// The reader started moving the transcript: end a programmatic-scroll
    /// hold early, or run a replay deferred at rest, now that SwiftUI
    /// re-anchors window changes against the moving content.
    func handleUserScrollInteractionBegan() {
        if isProgrammaticScrollHoldActive {
            taskManager.cancel(programmaticScrollHoldTaskKey)
            releaseProgrammaticScrollHold(isUserScrolling: true)
        } else if let index = deferredLeadingReplayIndex {
            deferredLeadingReplayIndex = nil
            replayHeldVisibleIndex(index, isUserScrolling: true)
        }
    }

    private func releaseProgrammaticScrollHold(isUserScrolling: Bool) {
        guard isProgrammaticScrollHoldActive else { return }
        isProgrammaticScrollHoldActive = false
        guard let index = heldVisibleIndex else { return }
        heldVisibleIndex = nil
        replayHeldVisibleIndex(index, isUserScrolling: isUserScrolling)
    }

    private func replayHeldVisibleIndex(_ index: Int, isUserScrolling: Bool) {
        // A window replaced meanwhile (a jump to the latest window after a
        // send) makes the held position meaningless; replaying it would pull
        // the window back toward the old range.
        guard let window = messageWindow,
              window.contains(index: index),
              !isInitialAnchorHoldActive,
              abs(index - scrollPosition) > 2 else { return }

        let requestedStartIndex = max(0, index - configuration.bufferSize)
        if requestedStartIndex < window.startIndex && !isUserScrolling {
            deferredLeadingReplayIndex = index
            return
        }

        scrollPosition = index
        // Extend rather than replace: the shift exposed a few rows at one
        // edge, and dropping the rows on the far side (above the viewport for
        // a keyboard show) moves the content under the reader even at rest.
        // An extension already leaves `bufferSize` rows of slack, so a
        // concurrent edge preload would only race it.
        if !updateVisibleMessages(extendsWindowOnOverlap: true) {
            preloadIfNeeded()
        }
    }

    /// Releases the initial-anchor hold on `markIndexVisible`; called by the
    /// view once the coordinator publishes `isReadyToShow` (a confirmed or
    /// fallback reveal, or a user-scroll takeover). `scrollPosition` stays
    /// parked at the window head until a genuine post-reveal position change.
    func endInitialAnchorHold() {
        isInitialAnchorHoldActive = false
    }

    /// Re-arms the initial-anchor hold for a restarted hidden reveal. The
    /// coordinator's empty-to-loaded restart re-hides the transcript and
    /// re-runs the anchor pass over rows published by `loadLatestWindow`,
    /// which parks `scrollPosition` at the window head but does not arm the
    /// hold itself — only `publishInitialWindow` does — so the view arms it
    /// when `isReadyToShow` drops back to false. No-op for beginning-anchored
    /// windows, which reveal at the top without an anchor pass.
    func beginInitialAnchorHold() {
        guard initialWindowPosition == .end else { return }
        isInitialAnchorHoldActive = true
    }

    var visibleRangeStartIndex: Int {
        messageWindow?.startIndex ?? 0
    }

    var isShowingLatestWindow: Bool {
        guard let messageWindow else { return false }
        return messageWindow.endIndex >= totalMessageCount ||
            !pendingInsertedMessageEvents.isEmpty
    }

    func setFollowsLatestInsertions(_ followsLatestInsertions: Bool) {
        guard self.followsLatestInsertions != followsLatestInsertions else { return }
        self.followsLatestInsertions = followsLatestInsertions
        followIntentRevision &+= 1

        if followsLatestInsertions {
            preloadNext()
        }
    }

    func shouldFollowLatestWindow(_ window: MessageWindow) -> Bool {
        followsLatestInsertions &&
            (window.endIndex >= totalMessageCount ||
                !pendingInsertedMessageEvents.isEmpty)
    }

    func isCurrentFollowIntent(_ requiredRevision: UInt?) -> Bool {
        guard let requiredRevision else { return true }
        return followsLatestInsertions && followIntentRevision == requiredRevision
    }

    private func isCurrentWindow(_ window: MessageWindow) -> Bool {
        guard let currentWindow = messageWindow else { return false }
        return currentWindow.startIndex == window.startIndex &&
            currentWindow.endIndex == window.endIndex &&
            currentWindow.messageIDs == window.messageIDs
    }

    func canRestoreCapturedWindow(_ window: MessageWindow) -> Bool {
        guard windowLoadLifecycle == .idle else { return false }
        return isCurrentWindow(window)
    }

    func canStartAutomaticReconciliation(_ window: MessageWindow) -> Bool {
        guard isCurrentWindow(window) else { return false }
        switch windowLoadLifecycle {
        case .idle:
            return true
        case .loadingInitialWindow:
            return false
        case .loadingWindow(.latest(let requiredFollowIntentRevision)):
            return requiredFollowIntentRevision != nil
        case .loadingWindow(.range):
            return false
        }
    }

    var hasPendingInsertedMessagesInConversation: Bool {
        guard let conversationUUID = UUID(uuidString: conversationId) else { return false }

        return viewContext.insertedObjects.contains { object in
            guard let message = object as? Message else { return false }
            return message.conversation?.id == conversationUUID
        }
    }

    func absoluteIndex(forVisibleIndex index: Int) -> Int? {
        guard index >= 0, index < visibleMessages.count else {
            return nil
        }

        return visibleRangeStartIndex + index
    }

    func finishWindowLoadFailure(operation: String, description: String) {
        if visibleMessages.isEmpty && initialLoadPhase == .loading {
            initialLoadFailureReason = "Messages couldn’t be loaded. Please try again."
            initialLoadPhase = .failed
        }
        Log.diagnostic(
            .chatView,
            level: .error,
            "VirtualScroll \(operation) failed conv=\(conversationId) error=\(description); preserving current window",
            category: .ui
        )
        // The deferred hand-off reads the failed load's intent to replay a
        // queued .latest/.range load, so it must run before the lifecycle
        // ends. Either way the lifecycle ends here: an intent outliving its
        // load is the reconciliation wedge the lifecycle enum exists to make
        // unrepresentable. Callers reach this terminal only for the current
        // generation.
        scheduleDeferredDatasetReconciliationIfNeeded()
        windowLoadLifecycle = .idle
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
        schedulePostSyncDatasetReconciliationIfNeeded()
    }

    func logPreloadFailure(direction: String, description: String) {
        Log.diagnostic(
            .chatView,
            level: .error,
            "VirtualScroll \(direction) preload failed conv=\(conversationId) error=\(description); preserving current window",
            category: .ui
        )
    }

    func updateAvailabilityPhaseAfterWindowLoad(
        page: VirtualScrollMessagePage,
        messages: [ChatMessageRowModel]
    ) {
        if !messages.isEmpty {
            if initialLoadPhase == .loading && initialWindowPosition == .end {
                // This publication is resolving the initial phase, so it is
                // the reveal's transcript: it inherits the initial publish's
                // duty to arm the onAppear hold. The superseded initial
                // publish that would have armed it is dropped, and the view's
                // true-to-false isReadyToShow seam cannot fire on a first
                // open — without this arm, the hidden anchor pass runs over
                // unheld rows and the pre-reveal prepend cascade returns.
                isInitialAnchorHoldActive = true
            }
            initialLoadFailureReason = nil
            initialLoadPhase = .loaded
        } else if page.totalCount == 0 {
            initialLoadFailureReason = nil
            initialLoadPhase = .empty
        }
    }

    func expectedMessageIDCount(
        in range: Range<Int>,
        totalCount: Int
    ) -> Int {
        max(0, min(range.upperBound, totalCount) - range.lowerBound)
    }

    func beginWindowLoad(intent: WindowLoadIntent) -> UInt {
        windowLoadGeneration &+= 1
        windowLoadLifecycle = .loadingWindow(intent: intent)
        return windowLoadGeneration
    }

    func finishCancelledWindowLoad(generation: UInt) {
        guard generation == windowLoadGeneration else { return }
        windowLoadLifecycle = .idle
    }

    /// Cancels all pending tasks when the scroll state is no longer needed
    func cleanup() {
        finishInitialLoadSignpost(outcome: "cancelled")
        windowLoadGeneration &+= 1
        taskManager.cancelAll()
        isProgrammaticScrollHoldActive = false
        heldVisibleIndex = nil
        deferredLeadingReplayIndex = nil
        windowLoadLifecycle = .idle
        needsDatasetReconciliationAfterCurrentLoad = false
        needsUnclassifiedRefreshCountReconciliation = false
        needsPostSyncDatasetReconciliation = false
        viewContextChangesCancellable?.cancel()
        viewContextChangesCancellable = nil
        syncCompletedCancellable?.cancel()
        syncCompletedCancellable = nil
    }

    /// Restores observation and any interrupted initial load when the chat reappears.
    func resume() {
        let wasInactive = viewContextChangesCancellable == nil
        startObservingViewContextChanges()
        guard wasInactive else { return }

        if initialLoadPhase == .loading {
            loadInitialMessages()
        } else if initialLoadPhase == .loaded || initialLoadPhase == .empty {
            taskManager.run("resumeWindow") { [weak self] in
                await self?.reconcileWindowAfterResume()
            }
        }
    }

    private func reconcileWindowAfterResume() async {
        guard initialLoadPhase == .loaded else {
            await loadLatestWindow()
            return
        }
        guard let messageWindow else {
            _ = await loadLatestWindow()
            return
        }
        guard canRestoreCapturedWindow(messageWindow) else { return }
        if shouldFollowLatestWindow(messageWindow) {
            let requiredFollowIntentRevision = followIntentRevision
            let didLoadLatest = await loadLatestWindow(
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
            if didLoadLatest || isCurrentFollowIntent(requiredFollowIntentRevision) {
                return
            }
        }

        guard canRestoreCapturedWindow(messageWindow) else { return }
        await reloadHistoricalWindowClamped(
            messageWindow,
            preferPendingConversationMessages: hasPendingInsertedMessagesInConversation
        )
    }

    func finishInitialLoadSignpost(outcome: String) {
        guard let interval = initialLoadSignpostInterval else { return }
        ChatViewPerformanceSignposts.endInitialLoad(
            interval,
            conversationID: conversationId,
            outcome: outcome,
            visibleRowCount: visibleMessages.count,
            totalCount: totalMessageCount
        )
        initialLoadSignpostInterval = nil
    }

}
