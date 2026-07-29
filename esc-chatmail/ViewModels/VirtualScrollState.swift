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

    private struct InitialWindowLoad {
        let range: Range<Int>
        let page: VirtualScrollMessagePage
        let messages: [ChatMessageRowModel]
    }

    private struct LoadedWindowBounds {
        let startIndex: Int
        let totalCount: Int
        let generation: UInt
    }

    private struct UncachedRefreshAssessment {
        var orderedDatasetDidChange = false
        var needsCountReconciliation = false
    }

    private enum WindowLoadIntent {
        case latest(requiredFollowIntentRevision: UInt?)
        case range(Range<Int>)
    }

    private enum InitialLoadAttemptFailure: Error {
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
    @Published var scrollPosition: Int = 0
    @Published var isLoadingMore = false
    @Published private(set) var initialLoadPhase: InitialLoadPhase = .loading
    @Published private(set) var initialLoadFailureReason: String?
    @Published var placeholderIndices: Set<Int> = []
    @Published private(set) var latestWindowLayoutID = UUID()

    var isInitialLoadComplete: Bool {
        initialLoadPhase == .loaded || initialLoadPhase == .empty
    }

    let insertedVisibleMessageEvents = PassthroughSubject<VirtualScrollInsertedMessageEvent, Never>()
    let refreshedInsertedMessageEvents = PassthroughSubject<VirtualScrollInsertedMessageRefresh, Never>()

    private let configuration: VirtualScrollConfiguration
    private let initialWindowPosition: InitialWindowPosition
    private var messageWindow: MessageWindow?
    private let conversationId: String
    private let viewContext: NSManagedObjectContext
    private let makeBackgroundContext: () -> NSManagedObjectContext
    private let pageLoader: MessagePageLoader

    // Cache only lightweight row snapshots for the current window. Background
    // contexts fetch IDs, and the UI never stores `Message` instances here.
    private var resolvedRowsByID: [NSManagedObjectID: ChatMessageRowModel] = [:]
    private var resolvedRowsByAbsoluteIndex: [Int: ChatMessageRowModel] = [:]
    private var viewContextChangesCancellable: AnyCancellable?
    private var syncCompletedCancellable: AnyCancellable?
    private var cachedConversationObjectID: NSManagedObjectID?
    private var pendingInsertedMessageEvents: [VirtualScrollInsertedMessageEvent] = []
    private var followsLatestInsertions = true
    private var followIntentRevision: UInt = 0

    // Task tracking to prevent orphaned tasks during rapid scrolling
    private let taskManager = ViewModelTaskManager()
    private let datasetReconcileTaskKey = "reconcileWindowAfterDatasetMutation"
    private let postSyncValidationTaskKey = "validateWindowAfterSync"
    private let unclassifiedRefreshCountTaskKey = "reconcileUnclassifiedRefreshCount"
    private let maximumAutomaticInitialLoadRetryCount = 1
    private let maximumAutomaticPostSyncValidationRetryCount = 1
    private let maximumExplicitMessageVisibilityRetryCount = 1
    private let initialLoadRetryDelayNanoseconds: UInt64 = 100_000_000
    private var initialLoadSignpostInterval: ChatViewPerformanceSignposts.Interval?
    private var windowLoadGeneration: UInt = 0
    private var messageDatasetGeneration: UInt = 0
    private var postSyncValidationRetryCount = 0
    private var needsDatasetReconciliationAfterCurrentLoad = false
    private var needsUnclassifiedRefreshCountReconciliation = false
    private var needsPostSyncDatasetReconciliation = false
    private var currentWindowLoadIntent: WindowLoadIntent?

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
        // Skip small position changes to avoid excessive updates during scroll
        // This prevents 10+ calls per scroll when each visible message fires onAppear
        guard abs(index - scrollPosition) > 2 else { return }

        scrollPosition = index
        updateVisibleMessages()
        preloadIfNeeded()
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

    private func shouldFollowLatestWindow(_ window: MessageWindow) -> Bool {
        followsLatestInsertions &&
            (window.endIndex >= totalMessageCount ||
                !pendingInsertedMessageEvents.isEmpty)
    }

    private func isCurrentFollowIntent(_ requiredRevision: UInt?) -> Bool {
        guard let requiredRevision else { return true }
        return followsLatestInsertions && followIntentRevision == requiredRevision
    }

    private func isCurrentWindow(_ window: MessageWindow) -> Bool {
        guard let currentWindow = messageWindow else { return false }
        return currentWindow.startIndex == window.startIndex &&
            currentWindow.endIndex == window.endIndex &&
            currentWindow.messageIDs == window.messageIDs
    }

    private func canRestoreCapturedWindow(_ window: MessageWindow) -> Bool {
        guard !isLoadingMore else { return false }
        guard case nil = currentWindowLoadIntent else { return false }
        return isCurrentWindow(window)
    }

    private func canStartAutomaticReconciliation(_ window: MessageWindow) -> Bool {
        guard isCurrentWindow(window) else { return false }
        guard isLoadingMore else {
            guard case nil = currentWindowLoadIntent else { return false }
            return true
        }

        if case .latest(let requiredFollowIntentRevision) = currentWindowLoadIntent {
            return requiredFollowIntentRevision != nil
        }
        return false
    }

    private var hasPendingInsertedMessagesInConversation: Bool {
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

    func retryInitialLoad() {
        loadInitialMessages()
    }

    private func loadInitialMessages() {
        finishInitialLoadSignpost(outcome: "restarted")
        initialLoadSignpostInterval = ChatViewPerformanceSignposts.beginInitialLoad(
            conversationID: conversationId
        )
        initialLoadPhase = .loading
        initialLoadFailureReason = nil
        isLoadingMore = true
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll initial load start conv=\(conversationId) position=\(initialWindowPosition.diagnosticName)",
            category: .ui
        )

        taskManager.run("loadInitial") { [weak self] in
            guard let self = self else { return }

            for retryCount in 0...self.maximumAutomaticInitialLoadRetryCount {
                let result = await self.loadInitialWindowAttempt()

                guard !Task.isCancelled else { return }

                switch result {
                case .success(let loadedWindow):
                    self.publishInitialWindow(loadedWindow)
                    return

                case .failure(let failure):
                    if retryCount < self.maximumAutomaticInitialLoadRetryCount {
                        Log.diagnostic(
                            .chatView,
                            level: .warning,
                            "VirtualScroll initial load retry conv=\(self.conversationId) attempt=\(retryCount + 1) reason=\(failure.diagnosticDescription)",
                            category: .ui
                        )

                        do {
                            try await Task.sleep(
                                nanoseconds: self.initialLoadRetryDelayNanoseconds
                            )
                        } catch {
                            return
                        }
                        continue
                    }

                    self.publishInitialLoadFailure(failure)
                    return
                }
            }
        }
    }

    private func loadInitialWindowAttempt() async -> Result<InitialWindowLoad, InitialLoadAttemptFailure> {
        do {
            let expectedDatasetGeneration = messageDatasetGeneration
            var preferPendingConversationMessages =
                initialWindowPosition == .end && hasPendingInsertedMessagesInConversation
            var initialRange = try await initialMessageRangeForInitialLoad(
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll initial load request conv=\(conversationId) range=\(initialRange.lowerBound)..<\(initialRange.upperBound)",
                category: .ui
            )
            var page = try await validatedInitialLoadPage(
                initialRange,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else {
                return .failure(.cancelled)
            }

            var remainingEndWindowRebaseAttempts = 2
            while true {
                guard !Task.isCancelled else {
                    return .failure(.cancelled)
                }
                guard expectedDatasetGeneration == messageDatasetGeneration else {
                    throw InitialLoadAttemptFailure.datasetChanged(
                        reportedTotalCount: page.totalCount
                    )
                }

                if shouldReloadInitialEndWindowForPendingLocalMessages(
                    preferredPendingMessages: preferPendingConversationMessages
                ) {
                    preferPendingConversationMessages = true
                    initialRange = try await initialMessageRangeForInitialLoad(
                        preferPendingConversationMessages: true
                    )
                    Log.diagnostic(
                        .chatView,
                        level: .info,
                        "VirtualScroll initial load switching to pending local messages conv=\(conversationId) range=\(initialRange.lowerBound)..<\(initialRange.upperBound)",
                        category: .ui
                    )
                    page = try await validatedInitialLoadPage(
                        initialRange,
                        preferPendingConversationMessages: true
                    )
                    continue
                }

                guard initialWindowPosition == .end,
                      page.totalCount != initialRange.upperBound else {
                    break
                }
                guard remainingEndWindowRebaseAttempts > 0 else {
                    throw InitialLoadAttemptFailure.inconsistentWindow(
                        totalCount: page.totalCount,
                        requestedIDCount: page.messageIDs.count,
                        resolvedRowCount: 0
                    )
                }

                remainingEndWindowRebaseAttempts -= 1
                let rebasedStartIndex = max(
                    0,
                    page.totalCount - configuration.visibleItemCount
                )
                initialRange = rebasedStartIndex..<page.totalCount
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "VirtualScroll initial latest-window count drift conv=\(conversationId) observedTotal=\(page.totalCount); rebasing to \(initialRange.lowerBound)..<\(initialRange.upperBound)",
                    category: .ui
                )
                page = try await validatedInitialLoadPage(
                    initialRange,
                    preferPendingConversationMessages: preferPendingConversationMessages
                )
            }

            if page.totalCount > 0 && page.messageIDs.isEmpty {
                throw InitialLoadAttemptFailure.inconsistentWindow(
                    totalCount: page.totalCount,
                    requestedIDCount: 0,
                    resolvedRowCount: 0
                )
            }
            let expectedIDCount = expectedMessageIDCount(
                in: initialRange,
                totalCount: page.totalCount
            )
            guard page.messageIDs.count == expectedIDCount else {
                throw InitialLoadAttemptFailure.inconsistentWindow(
                    totalCount: page.totalCount,
                    requestedIDCount: page.messageIDs.count,
                    resolvedRowCount: 0
                )
            }

            let messages: [ChatMessageRowModel]
            do {
                messages = try resolveRowsOnViewContextThrowing(for: page.messageIDs)
            } catch {
                throw InitialLoadAttemptFailure.rowFetchFailed(
                    description: error.localizedDescription,
                    reportedTotalCount: page.totalCount
                )
            }

            guard !Task.isCancelled else {
                return .failure(.cancelled)
            }
            guard expectedDatasetGeneration == messageDatasetGeneration else {
                throw InitialLoadAttemptFailure.datasetChanged(
                    reportedTotalCount: page.totalCount
                )
            }

            guard messages.count == page.messageIDs.count else {
                throw InitialLoadAttemptFailure.inconsistentWindow(
                    totalCount: page.totalCount,
                    requestedIDCount: page.messageIDs.count,
                    resolvedRowCount: messages.count
                )
            }

            let loadedRange = page.totalCount == 0 ? 0..<0 : initialRange
            return .success(
                InitialWindowLoad(
                    range: loadedRange,
                    page: page,
                    messages: messages
                )
            )
        } catch let failure as InitialLoadAttemptFailure {
            return .failure(failure)
        } catch {
            return .failure(
                .pageFetchFailed(
                    description: error.localizedDescription,
                    reportedTotalCount: nil
                )
            )
        }
    }

    private func initialMessageRangeForInitialLoad(
        preferPendingConversationMessages: Bool
    ) async throws -> Range<Int> {
        switch initialWindowPosition {
        case .beginning:
            return 0..<configuration.visibleItemCount
        case .end:
            let metadataPage = try await validatedInitialLoadPage(
                0..<0,
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            let startIndex = max(0, metadataPage.totalCount - configuration.visibleItemCount)
            return startIndex..<metadataPage.totalCount
        }
    }

    private func validatedInitialLoadPage(
        _ range: Range<Int>,
        preferPendingConversationMessages: Bool
    ) async throws -> VirtualScrollMessagePage {
        let page = await loadPage(
            range,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        if let fetchErrorDescription = page.fetchErrorDescription {
            throw InitialLoadAttemptFailure.pageFetchFailed(
                description: fetchErrorDescription,
                reportedTotalCount: page.totalCount
            )
        }

        return page
    }

    private func publishInitialWindow(_ loadedWindow: InitialWindowLoad) {
        let page = loadedWindow.page
        let endIndex = loadedWindow.range.lowerBound + page.messageIDs.count
        let window = MessageWindow(
            startIndex: loadedWindow.range.lowerBound,
            endIndex: endIndex,
            messageIDs: page.messageIDs,
            isLoading: false
        )

        totalMessageCount = page.totalCount
        scrollPosition = loadedWindow.range.lowerBound
        setMessageWindow(window)
        visibleMessages = loadedWindow.messages
        placeholderIndices.removeAll()
        isLoadingMore = false
        needsDatasetReconciliationAfterCurrentLoad = false
        initialLoadFailureReason = nil
        initialLoadPhase = loadedWindow.messages.isEmpty ? .empty : .loaded
        if !loadedWindow.messages.isEmpty {
            ChatViewPerformanceSignposts.firstRowsResolved(
                conversationID: conversationId,
                count: loadedWindow.messages.count
            )
        }
        resolvePendingInsertedMessageEvents()
        finishInitialLoadSignpost(
            outcome: loadedWindow.messages.isEmpty ? "empty" : "loaded"
        )
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
        schedulePostSyncDatasetReconciliationIfNeeded()
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll initial load complete conv=\(conversationId) requested=\(loadedWindow.range.lowerBound)..<\(loadedWindow.range.upperBound) loaded=\(page.messageIDs.count) total=\(page.totalCount) window=\(window.startIndex)..<\(window.endIndex)",
            category: .ui
        )
    }

    private func publishInitialLoadFailure(_ failure: InitialLoadAttemptFailure) {
        if let reportedTotalCount = failure.reportedTotalCount {
            totalMessageCount = reportedTotalCount
        }
        placeholderIndices.removeAll()
        isLoadingMore = false
        initialLoadFailureReason = failure.userFacingReason
        initialLoadPhase = .failed
        finishInitialLoadSignpost(outcome: "failed")
        Log.diagnostic(
            .chatView,
            level: .error,
            "VirtualScroll initial load failed conv=\(conversationId) reason=\(failure.diagnosticDescription)",
            category: .ui
        )
    }

    @discardableResult
    func loadLatestWindowIfNeeded(knownTotalCount: Int? = nil) async -> Bool {
        let knownCountIsAhead = knownTotalCount.map { $0 > totalMessageCount } ?? false
        guard knownCountIsAhead ||
            !isShowingLatestWindow ||
            visibleMessages.isEmpty ||
            !pendingInsertedMessageEvents.isEmpty ||
            hasPendingInsertedMessagesInConversation else {
            return true
        }

        return await loadLatestWindow()
    }

    /// Ensures a specific, permanently identified message is published in the
    /// latest visible window before a caller performs message-targeted work such
    /// as post-send anchoring.
    @discardableResult
    func ensureVisibleMessage(_ objectID: NSManagedObjectID) async -> Bool {
        guard !objectID.isTemporaryID else { return false }

        return await ensureVisibleMessage(
            objectID,
            retryAttemptsRemaining: maximumExplicitMessageVisibilityRetryCount
        )
    }

    private func ensureVisibleMessage(
        _ objectID: NSManagedObjectID,
        retryAttemptsRemaining: Int
    ) async -> Bool {
        if visibleMessages.contains(where: { $0.objectID == objectID }) {
            return true
        }

        // This is an explicit local-send reconciliation, so it intentionally
        // carries no follow-intent revision. User scroll takeover may suppress
        // automatic latest following, but must not suppress publishing the
        // optimistic row itself. Force the view-context path so unsaved pending
        // inserts are included.
        _ = await loadLatestWindow(forceViewContext: true)

        if visibleMessages.contains(where: { $0.objectID == objectID }) {
            return true
        }

        guard !Task.isCancelled, retryAttemptsRemaining > 0 else {
            return false
        }

        // A competing dataset reconciliation can supersede a window generation.
        // Yield once before the single bounded retry so that work can publish.
        await Task.yield()
        return await ensureVisibleMessage(
            objectID,
            retryAttemptsRemaining: retryAttemptsRemaining - 1
        )
    }

    @discardableResult
    func loadLatestWindow(
        forceViewContext: Bool = false,
        datasetRetryAttemptsRemaining: Int = 1,
        requiredFollowIntentRevision: UInt? = nil
    ) async -> Bool {
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            return false
        }
        if visibleMessages.isEmpty &&
            (initialLoadPhase == .empty || initialLoadPhase == .failed) {
            initialLoadFailureReason = nil
            initialLoadPhase = .loading
        }
        let preferPendingConversationMessages =
            forceViewContext || hasPendingInsertedMessagesInConversation
        let loadGeneration = beginWindowLoad(
            intent: .latest(
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        )
        let expectedDatasetGeneration = messageDatasetGeneration
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll latest window load start conv=\(conversationId) preferPending=\(preferPendingConversationMessages)",
            category: .ui
        )
        let loadedTotalCount = await loadTotalMessageCount(
            preferPendingConversationMessages: preferPendingConversationMessages
        )
        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return false
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return false
        }
        guard loadGeneration == windowLoadGeneration else { return false }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            guard datasetRetryAttemptsRemaining > 0 else {
                finishWindowLoadFailure(
                    operation: "latest window metadata",
                    description: "message dataset kept changing while loading"
                )
                return false
            }
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll latest metadata changed during load; retrying conv=\(conversationId)",
                category: .ui
            )
            return await loadLatestWindow(
                forceViewContext: forceViewContext,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining - 1,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        }
        guard let totalCount = loadedTotalCount else {
            finishWindowLoadFailure(
                operation: "latest window metadata",
                description: "unable to fetch message count"
            )
            return false
        }
        let startIndex = max(0, totalCount - configuration.visibleItemCount)
        guard let loadedBounds = await loadWindow(
            startIndex: startIndex,
            endIndex: totalCount,
            preferPendingConversationMessages: preferPendingConversationMessages,
            latestRebaseAttemptsRemaining: 2,
            generation: loadGeneration,
            datasetGeneration: expectedDatasetGeneration,
            datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
            requiredFollowIntentRevision: requiredFollowIntentRevision
        ) else {
            return false
        }
        guard loadedBounds.generation == windowLoadGeneration else { return false }
        if isCurrentFollowIntent(requiredFollowIntentRevision) {
            scrollPosition = max(
                loadedBounds.startIndex,
                loadedBounds.totalCount - 1
            )
        }
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll latest window load complete conv=\(conversationId) total=\(loadedBounds.totalCount) window=\(loadedBounds.startIndex)..<\(loadedBounds.totalCount)",
            category: .ui
        )
        return true
    }

    private func retryWindowAfterDatasetChange(
        startIndex: Int,
        endIndex: Int,
        preferPendingConversationMessages: Bool,
        latestRebaseAttemptsRemaining: Int?,
        rangeClampAttemptsRemaining: Int,
        generation: UInt,
        datasetRetryAttemptsRemaining: Int,
        requiredFollowIntentRevision: UInt?,
        operation: String
    ) async -> LoadedWindowBounds? {
        guard datasetRetryAttemptsRemaining > 0 else {
            finishWindowLoadFailure(
                operation: operation,
                description: "message dataset kept changing while loading"
            )
            return nil
        }

        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll \(operation) dataset changed; retrying conv=\(conversationId)",
            category: .ui
        )
        return await loadWindow(
            startIndex: startIndex,
            endIndex: endIndex,
            preferPendingConversationMessages:
                preferPendingConversationMessages || hasPendingInsertedMessagesInConversation,
            latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining,
            rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
            generation: generation,
            datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining - 1,
            requiredFollowIntentRevision: requiredFollowIntentRevision
        )
    }

    private func updateVisibleMessages() {
        guard let window = messageWindow else { return }

        let startIndex = max(0, scrollPosition - configuration.bufferSize)
        let endIndex = min(totalMessageCount, scrollPosition + configuration.visibleItemCount + configuration.bufferSize)

        if window.contains(index: startIndex) && window.contains(index: endIndex - 1) {
            // Current window already covers the requested range.
            // Keep rendering the whole window so the user can continue scrolling
            // through the buffered messages without the view pruning rows away.
            visibleMessages = resolveCachedRows(for: window.messageIDs)
        } else {
            // Need to load a new window.
            let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
            taskManager.run("loadWindow") { [weak self] in
                guard let self = self else { return }
                _ = await self.loadWindow(
                    startIndex: startIndex,
                    endIndex: endIndex,
                    preferPendingConversationMessages: preferPendingConversationMessages
                )
            }
        }
    }

    private func loadWindow(
        startIndex: Int,
        endIndex: Int,
        preferPendingConversationMessages: Bool = false,
        latestRebaseAttemptsRemaining: Int? = nil,
        rangeClampAttemptsRemaining: Int = 1,
        generation: UInt? = nil,
        datasetGeneration: UInt? = nil,
        datasetRetryAttemptsRemaining: Int = 1,
        requiredFollowIntentRevision: UInt? = nil
    ) async -> LoadedWindowBounds? {
        guard startIndex >= 0, endIndex >= startIndex else {
            return nil
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            if let generation {
                finishCancelledWindowLoad(generation: generation)
            }
            return nil
        }

        let loadGeneration = generation ?? beginWindowLoad(
            intent: .range(startIndex..<endIndex)
        )
        let expectedDatasetGeneration = datasetGeneration ?? messageDatasetGeneration
        guard loadGeneration == windowLoadGeneration else { return nil }
        isLoadingMore = true

        // Show placeholders while loading
        placeholderIndices = Set(startIndex..<endIndex)

        let page = await loadPage(
            startIndex..<endIndex,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }
        guard loadGeneration == windowLoadGeneration else {
            return nil
        }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            return await retryWindowAfterDatasetChange(
                startIndex: startIndex,
                endIndex: endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages,
                latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
                generation: loadGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision,
                operation: "window"
            )
        }

        guard page.fetchErrorDescription == nil else {
            finishWindowLoadFailure(
                operation: "window",
                description: page.fetchErrorDescription ?? "Unknown fetch error"
            )
            return nil
        }

        if let latestRebaseAttemptsRemaining, page.totalCount != endIndex {
            guard latestRebaseAttemptsRemaining > 0 else {
                finishWindowLoadFailure(
                    operation: "latest window",
                    description: "message count kept changing while rebasing"
                )
                return nil
            }
            let rebasedStartIndex = max(
                0,
                page.totalCount - configuration.visibleItemCount
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll latest window count drift conv=\(conversationId) requested=\(startIndex)..<\(endIndex) observedTotal=\(page.totalCount); rebasing",
                category: .ui
            )
            return await loadWindow(
                startIndex: rebasedStartIndex,
                endIndex: page.totalCount,
                preferPendingConversationMessages: preferPendingConversationMessages,
                latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining - 1,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
                generation: loadGeneration,
                datasetGeneration: expectedDatasetGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        }

        if latestRebaseAttemptsRemaining == nil,
           page.totalCount > 0,
           endIndex > page.totalCount,
           rangeClampAttemptsRemaining > 0 {
            let desiredWindowCount = max(1, endIndex - startIndex)
            let latestPossibleStart = max(0, page.totalCount - desiredWindowCount)
            let adjustedStartIndex = min(startIndex, latestPossibleStart)
            let adjustedEndIndex = min(
                page.totalCount,
                adjustedStartIndex + desiredWindowCount
            )

            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll window count drift conv=\(conversationId) requested=\(startIndex)..<\(endIndex) observedTotal=\(page.totalCount); clamping to \(adjustedStartIndex)..<\(adjustedEndIndex)",
                category: .ui
            )
            return await loadWindow(
                startIndex: adjustedStartIndex,
                endIndex: adjustedEndIndex,
                preferPendingConversationMessages: preferPendingConversationMessages,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining - 1,
                generation: loadGeneration,
                datasetGeneration: expectedDatasetGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        }

        let expectedIDCount = expectedMessageIDCount(
            in: startIndex..<endIndex,
            totalCount: page.totalCount
        )
        guard page.totalCount == 0 || expectedIDCount > 0 else {
            finishWindowLoadFailure(
                operation: "window",
                description: "range \(startIndex)..<\(endIndex) is outside observed total \(page.totalCount)"
            )
            return nil
        }
        guard page.messageIDs.count == expectedIDCount else {
            finishWindowLoadFailure(
                operation: "window",
                description: "received \(page.messageIDs.count) IDs, expected \(expectedIDCount), for range \(startIndex)..<\(endIndex) with total \(page.totalCount)"
            )
            return nil
        }

        let messages: [ChatMessageRowModel]
        do {
            messages = try resolveRowsOnViewContextThrowing(for: page.messageIDs)
        } catch {
            finishWindowLoadFailure(
                operation: "window row resolution",
                description: error.localizedDescription
            )
            return nil
        }

        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }
        guard loadGeneration == windowLoadGeneration else {
            return nil
        }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            return await retryWindowAfterDatasetChange(
                startIndex: startIndex,
                endIndex: endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages,
                latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
                generation: loadGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision,
                operation: "window row resolution"
            )
        }
        guard messages.count == page.messageIDs.count else {
            finishWindowLoadFailure(
                operation: "window row resolution",
                description: "resolved \(messages.count) of \(page.messageIDs.count) rows"
            )
            return nil
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }

        let publishedStartIndex = page.totalCount == 0 ? 0 : startIndex
        let loadedEndIndex = publishedStartIndex + page.messageIDs.count
        let window = MessageWindow(
            startIndex: publishedStartIndex,
            endIndex: loadedEndIndex,
            messageIDs: page.messageIDs,
            isLoading: false
        )

        totalMessageCount = page.totalCount
        setMessageWindow(window)
        visibleMessages = messages
        placeholderIndices.removeAll()
        isLoadingMore = false
        updateAvailabilityPhaseAfterWindowLoad(page: page, messages: messages)
        needsDatasetReconciliationAfterCurrentLoad = false
        currentWindowLoadIntent = nil
        resolvePendingInsertedMessageEvents()
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
        schedulePostSyncDatasetReconciliationIfNeeded()
        return LoadedWindowBounds(
            startIndex: publishedStartIndex,
            totalCount: page.totalCount,
            generation: loadGeneration
        )
    }

    private func loadTotalMessageCount(
        preferPendingConversationMessages: Bool = false
    ) async -> Int? {
        let metadataPage = await loadPage(
            0..<0,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        if let fetchErrorDescription = metadataPage.fetchErrorDescription {
            Log.diagnostic(
                .chatView,
                level: .error,
                "VirtualScroll metadata load failed conv=\(conversationId) error=\(fetchErrorDescription)",
                category: .ui
            )
            return nil
        }

        return metadataPage.totalCount
    }

    private func shouldReloadInitialEndWindowForPendingLocalMessages(
        preferredPendingMessages: Bool
    ) -> Bool {
        initialWindowPosition == .end &&
            !preferredPendingMessages &&
            hasPendingInsertedMessagesInConversation
    }

    private func loadPage(
        _ range: Range<Int>,
        preferPendingConversationMessages: Bool = false
    ) async -> VirtualScrollMessagePage {
        if preferPendingConversationMessages {
            return await Self.loadPendingMessagePage(
                conversationId: conversationId,
                range: range,
                in: viewContext
            )
        }

        return await pageLoader(conversationId, range, makeBackgroundContext())
    }

    private func preloadIfNeeded() {
        guard let window = messageWindow else { return }

        let distanceToEnd = window.endIndex - scrollPosition
        if distanceToEnd < configuration.preloadThreshold {
            preloadNext()
        }

        let distanceToStart = scrollPosition - window.startIndex
        if distanceToStart < configuration.preloadThreshold {
            preloadPrevious()
        }
    }

    private func preloadNext() {
        guard let window = messageWindow,
              window.endIndex < totalMessageCount else { return }

        let startIndex = window.endIndex
        let endIndex = min(totalMessageCount, startIndex + configuration.pageSize)
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
        let expectedTotalCount = totalMessageCount
        let expectedDatasetGeneration = messageDatasetGeneration

        taskManager.run("preloadNext") { [weak self] in
            guard let self = self else { return }

            let page = await self.loadPage(
                startIndex..<endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }
            guard page.fetchErrorDescription == nil else {
                self.logPreloadFailure(
                    direction: "next",
                    description: page.fetchErrorDescription ?? "Unknown fetch error"
                )
                return
            }
            guard self.messageDatasetGeneration == expectedDatasetGeneration,
                  page.totalCount == expectedTotalCount else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "message dataset changed while loading"
                )
                return
            }
            guard Set(page.messageIDs).isDisjoint(with: window.messageIDs) else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "page overlapped the captured window"
                )
                return
            }
            let expectedIDCount = self.expectedMessageIDCount(
                in: startIndex..<endIndex,
                totalCount: page.totalCount
            )
            guard expectedIDCount > 0, page.messageIDs.count == expectedIDCount else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "received \(page.messageIDs.count) IDs, expected \(expectedIDCount), for range \(startIndex)..<\(endIndex) with total \(page.totalCount)"
                )
                return
            }

            let messages: [ChatMessageRowModel]
            do {
                messages = try self.resolveRowsOnViewContextThrowing(for: page.messageIDs)
            } catch {
                self.logPreloadFailure(
                    direction: "next",
                    description: error.localizedDescription
                )
                return
            }

            guard !Task.isCancelled else { return }
            guard messages.count == page.messageIDs.count else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "resolved \(messages.count) of \(page.messageIDs.count) rows"
                )
                return
            }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs.append(contentsOf: page.messageIDs)
            currentWindow = MessageWindow(
                startIndex: currentWindow.startIndex,
                endIndex: startIndex + page.messageIDs.count,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            ).frontTrimmed(to: self.configuration.maxWindowSize)

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedRows(for: currentWindow.messageIDs)
            self.schedulePostSyncDatasetReconciliationIfNeeded()
        }
    }

    private func preloadPrevious() {
        guard let window = messageWindow,
              window.startIndex > 0 else { return }

        let endIndex = window.startIndex
        let startIndex = max(0, endIndex - configuration.pageSize)
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
        let expectedTotalCount = totalMessageCount
        let expectedDatasetGeneration = messageDatasetGeneration

        taskManager.run("preloadPrevious") { [weak self] in
            guard let self = self else { return }

            let page = await self.loadPage(
                startIndex..<endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }
            guard page.fetchErrorDescription == nil else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: page.fetchErrorDescription ?? "Unknown fetch error"
                )
                return
            }
            guard self.messageDatasetGeneration == expectedDatasetGeneration,
                  page.totalCount == expectedTotalCount else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "message dataset changed while loading"
                )
                return
            }
            guard Set(page.messageIDs).isDisjoint(with: window.messageIDs) else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "page overlapped the captured window"
                )
                return
            }
            let expectedIDCount = self.expectedMessageIDCount(
                in: startIndex..<endIndex,
                totalCount: page.totalCount
            )
            guard expectedIDCount > 0, page.messageIDs.count == expectedIDCount else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "received \(page.messageIDs.count) IDs, expected \(expectedIDCount), for range \(startIndex)..<\(endIndex) with total \(page.totalCount)"
                )
                return
            }

            let messages: [ChatMessageRowModel]
            do {
                messages = try self.resolveRowsOnViewContextThrowing(for: page.messageIDs)
            } catch {
                self.logPreloadFailure(
                    direction: "previous",
                    description: error.localizedDescription
                )
                return
            }

            guard !Task.isCancelled else { return }
            guard messages.count == page.messageIDs.count else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "resolved \(messages.count) of \(page.messageIDs.count) rows"
                )
                return
            }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs = page.messageIDs + currentWindow.messageIDs

            // Back-trim against the window cap: the user is scrolling UP, so
            // the trimmed rows are far below the viewport and their removal
            // cannot shift visible content.
            currentWindow = MessageWindow(
                startIndex: startIndex,
                endIndex: currentWindow.endIndex,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            ).backTrimmed(to: self.configuration.maxWindowSize)

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedRows(for: currentWindow.messageIDs)
            self.schedulePostSyncDatasetReconciliationIfNeeded()
        }
    }

    private func finishWindowLoadFailure(operation: String, description: String) {
        placeholderIndices.removeAll()
        isLoadingMore = false
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
        scheduleDeferredDatasetReconciliationIfNeeded()
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
        schedulePostSyncDatasetReconciliationIfNeeded()
    }

    private func logPreloadFailure(direction: String, description: String) {
        Log.diagnostic(
            .chatView,
            level: .error,
            "VirtualScroll \(direction) preload failed conv=\(conversationId) error=\(description); preserving current window",
            category: .ui
        )
    }

    private func updateAvailabilityPhaseAfterWindowLoad(
        page: VirtualScrollMessagePage,
        messages: [ChatMessageRowModel]
    ) {
        if !messages.isEmpty {
            initialLoadFailureReason = nil
            initialLoadPhase = .loaded
        } else if page.totalCount == 0 {
            initialLoadFailureReason = nil
            initialLoadPhase = .empty
        }
    }

    private func expectedMessageIDCount(
        in range: Range<Int>,
        totalCount: Int
    ) -> Int {
        max(0, min(range.upperBound, totalCount) - range.lowerBound)
    }

    private func beginWindowLoad(intent: WindowLoadIntent) -> UInt {
        windowLoadGeneration &+= 1
        currentWindowLoadIntent = intent
        isLoadingMore = true
        return windowLoadGeneration
    }

    private func finishCancelledWindowLoad(generation: UInt) {
        guard generation == windowLoadGeneration else { return }
        placeholderIndices.removeAll()
        isLoadingMore = false
        currentWindowLoadIntent = nil
    }

    /// Cancels all pending tasks when the scroll state is no longer needed
    func cleanup() {
        finishInitialLoadSignpost(outcome: "cancelled")
        windowLoadGeneration &+= 1
        taskManager.cancelAll()
        placeholderIndices.removeAll()
        isLoadingMore = false
        needsDatasetReconciliationAfterCurrentLoad = false
        needsUnclassifiedRefreshCountReconciliation = false
        needsPostSyncDatasetReconciliation = false
        currentWindowLoadIntent = nil
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

    private func finishInitialLoadSignpost(outcome: String) {
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

    private func startObservingViewContextChanges() {
        if viewContextChangesCancellable == nil {
            viewContextChangesCancellable = NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: viewContext
            )
            .sink { [weak self] notification in
                self?.handleViewContextChange(notification)
            }
        }

        if syncCompletedCancellable == nil {
            syncCompletedCancellable = NotificationCenter.default.publisher(
                for: .syncCompleted
            )
            .sink { [weak self] _ in
                self?.schedulePostSyncDatasetReconciliationIfNeeded(
                    syncDidComplete: true
                )
            }
        }
    }

    private func handleViewContextChange(_ notification: Notification) {
        // objectsDidChange fires for every merged sync save while a chat is
        // open. Bail out on type checks alone before any pass below faults
        // objects: only Message/Attachment changes and Person display-name
        // updates can affect this window.
        guard Self.isRelevantChatContextChange(notification.userInfo) else { return }

        let insertedMessageIDs = visibleInsertedMessageIDsForCurrentConversation(
            in: notification
        )
        let hasVisibleInsertion = hasVisibleInsertedMessageForCurrentConversation(
            in: notification
        )
        let deletedMessages = contextObjects(
            forKeys: [NSDeletedObjectsKey],
            in: notification
        ).compactMap { $0 as? Message }
        let deletedMessageIDs = Set(deletedMessages.map(\.objectID))
        let hasCurrentConversationDeletion = deletedMessages.contains {
            belongsToCurrentConversation($0)
        }
        let hasDeletedWindowMessage = messageWindow.map {
            !Set($0.messageIDs).isDisjoint(with: deletedMessageIDs)
        } ?? false
        let uncachedRefreshAssessment = assessUncachedRefreshedMessages(
            in: notification
        )
        let hasOrderedDatasetUpdate = containsOrderedDatasetAffectingMessageUpdate(
            notification
        )
        let orderedDatasetDidChange =
            hasVisibleInsertion ||
            hasCurrentConversationDeletion ||
            hasDeletedWindowMessage ||
            hasOrderedDatasetUpdate ||
            uncachedRefreshAssessment.orderedDatasetDidChange

        if uncachedRefreshAssessment.needsCountReconciliation {
            needsUnclassifiedRefreshCountReconciliation = true
        }
        if orderedDatasetDidChange {
            messageDatasetGeneration &+= 1
        }
        guard let window = messageWindow else { return }

        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)
        let canPreserveHistoricalWindowForTailInsertion =
            !shouldFollowLatestWindow &&
            hasVisibleInsertion &&
            !hasCurrentConversationDeletion &&
            !hasDeletedWindowMessage &&
            !hasOrderedDatasetUpdate &&
            visibleInsertedMessagesSortStrictlyAfterWindow(
                in: notification,
                window: window
            )
        let requiresWindowReconciliation =
            orderedDatasetDidChange &&
            !canPreserveHistoricalWindowForTailInsertion
        let knownTotalCount = estimatedTotalCountAfterLocalMessageMutation(in: notification)
        if !insertedMessageIDs.isEmpty {
            let event = VirtualScrollInsertedMessageEvent(
                id: UUID(),
                messageIDs: insertedMessageIDs
            )
            insertedVisibleMessageEvents.send(event)
            if shouldFollowLatestWindow {
                let autoReadMessageIDs = newestVisibleInsertedMessageIDsForCurrentConversation(
                    in: notification
                )
                pendingInsertedMessageEvents.append(
                    VirtualScrollInsertedMessageEvent(
                        id: event.id,
                        messageIDs: autoReadMessageIDs
                    )
                )
            }
        }

        if knownTotalCount > totalMessageCount {
            resolvedRowsByAbsoluteIndex.removeAll()
            totalMessageCount = knownTotalCount
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll local message mutation count updated conv=\(conversationId) knownTotal=\(knownTotalCount)",
                category: .ui
            )
        }

        let boundaryMessageIDs = Set(resolvedRowsByAbsoluteIndex.values.map(\.objectID))
        let cachedMessageIDs = Set(window.messageIDs).union(boundaryMessageIDs)
        let affectedMessageIDs = cachedMessageIDs.isEmpty
            ? []
            : refreshedCachedMessageIDs(
                in: notification,
                cachedMessageIDs: cachedMessageIDs
            )

        let didInvalidateBoundaryRow = !boundaryMessageIDs.isDisjoint(
            with: affectedMessageIDs
        )
        invalidateCachedRows(for: affectedMessageIDs)

        if requiresWindowReconciliation {
            // An in-flight range/latest load owns the user's current scroll
            // intent. Its dataset token forces a bounded retry, so starting a
            // second reconciliation here would only invalidate that retry.
            if !isLoadingMore {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "VirtualScroll dataset reconciliation requested conv=\(conversationId) followsLatest=\(shouldFollowLatestWindow) knownTotal=\(knownTotalCount)",
                    category: .ui
                )
                taskManager.run(datasetReconcileTaskKey) { [weak self] in
                    guard let self else { return }
                    await self.reconcileWindowAfterDatasetMutation(
                        window: window,
                        shouldFollowLatestWindow: shouldFollowLatestWindow
                    )
                }
            } else {
                needsDatasetReconciliationAfterCurrentLoad = true
            }
            scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
            return
        }

        if !affectedMessageIDs.isEmpty {
            let refreshedRows = resolveCachedRows(for: window.messageIDs)
            if didInvalidateBoundaryRow || refreshedRows != visibleMessages {
                visibleMessages = refreshedRows
            }
        }
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
    }

    @discardableResult
    private func reconcileWindowAfterDatasetMutation(
        window: MessageWindow,
        shouldFollowLatestWindow: Bool
    ) async -> Bool {
        guard canStartAutomaticReconciliation(window) else { return false }
        if shouldFollowLatestWindow && self.shouldFollowLatestWindow(window) {
            let requiredFollowIntentRevision = followIntentRevision
            let didLoadLatest = await loadLatestWindow(
                forceViewContext: true,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
            if didLoadLatest {
                return true
            }
            guard !isCurrentFollowIntent(requiredFollowIntentRevision) else {
                return false
            }
        }

        guard canRestoreCapturedWindow(window) else { return false }
        return await reloadHistoricalWindowClamped(
            window,
            preferPendingConversationMessages: true
        )
    }

    private func scheduleDeferredDatasetReconciliationIfNeeded() {
        guard needsDatasetReconciliationAfterCurrentLoad,
              let window = messageWindow else {
            return
        }

        needsDatasetReconciliationAfterCurrentLoad = false
        let loadIntent = currentWindowLoadIntent
        currentWindowLoadIntent = nil
        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)
        taskManager.run(datasetReconcileTaskKey) { [weak self] in
            guard let self else { return }
            guard self.canRestoreCapturedWindow(window) else { return }
            switch loadIntent {
            case .latest(let requiredFollowIntentRevision):
                let didLoadLatest = await self.loadLatestWindow(
                    forceViewContext: true,
                    requiredFollowIntentRevision: requiredFollowIntentRevision
                )
                if !didLoadLatest,
                   !self.isCurrentFollowIntent(requiredFollowIntentRevision),
                   self.canRestoreCapturedWindow(window) {
                    _ = await self.reloadHistoricalWindowClamped(
                        window,
                        preferPendingConversationMessages: true
                    )
                }
            case .range(let range):
                _ = await self.loadWindow(
                    startIndex: range.lowerBound,
                    endIndex: range.upperBound,
                    preferPendingConversationMessages: true
                )
            case nil:
                await self.reconcileWindowAfterDatasetMutation(
                    window: window,
                    shouldFollowLatestWindow: shouldFollowLatestWindow
                )
            }
        }
    }

    private func scheduleUnclassifiedRefreshCountReconciliationIfNeeded() {
        guard needsUnclassifiedRefreshCountReconciliation,
              isInitialLoadComplete,
              !isLoadingMore,
              messageWindow != nil else {
            return
        }

        taskManager.run(unclassifiedRefreshCountTaskKey) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            await self?.reconcileUnclassifiedRefreshCountIfNeeded()
        }
    }

    private func reconcileUnclassifiedRefreshCountIfNeeded() async {
        guard needsUnclassifiedRefreshCountReconciliation else { return }
        needsUnclassifiedRefreshCountReconciliation = false

        let observedCount = await loadTotalMessageCount(
            preferPendingConversationMessages: hasPendingInsertedMessagesInConversation
        )
        guard !Task.isCancelled, let observedCount else { return }
        guard observedCount != totalMessageCount else { return }

        messageDatasetGeneration &+= 1
        guard let window = messageWindow else { return }
        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)

        if isLoadingMore {
            needsDatasetReconciliationAfterCurrentLoad = true
            return
        }

        await reconcileWindowAfterDatasetMutation(
            window: window,
            shouldFollowLatestWindow: shouldFollowLatestWindow
        )
    }

    private func schedulePostSyncDatasetReconciliationIfNeeded(
        syncDidComplete: Bool = false
    ) {
        if syncDidComplete {
            needsPostSyncDatasetReconciliation = true
            postSyncValidationRetryCount = 0
        }
        guard needsPostSyncDatasetReconciliation else { return }
        guard isInitialLoadComplete,
              !isLoadingMore,
              let window = messageWindow else {
            return
        }

        needsPostSyncDatasetReconciliation = false
        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)
        taskManager.run(postSyncValidationTaskKey) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await self.validateWindowAfterSync(
                window: window,
                shouldFollowLatestWindow: shouldFollowLatestWindow
            )
        }
    }

    private func validateWindowAfterSync(
        window: MessageWindow,
        shouldFollowLatestWindow: Bool
    ) async {
        let page = await loadPage(
            window.startIndex..<window.endIndex,
            preferPendingConversationMessages: hasPendingInsertedMessagesInConversation
        )
        guard !Task.isCancelled else { return }

        guard page.fetchErrorDescription == nil else {
            needsPostSyncDatasetReconciliation = true
            Log.diagnostic(
                .chatView,
                level: .error,
                "VirtualScroll post-sync validation failed conv=\(conversationId) error=\(page.fetchErrorDescription ?? "Unknown fetch error")",
                category: .ui
            )
            if postSyncValidationRetryCount < maximumAutomaticPostSyncValidationRetryCount {
                postSyncValidationRetryCount += 1
                schedulePostSyncDatasetReconciliationIfNeeded()
            }
            return
        }
        guard let currentWindow = messageWindow,
              currentWindow.startIndex == window.startIndex,
              currentWindow.endIndex == window.endIndex,
              currentWindow.messageIDs == window.messageIDs else {
            needsPostSyncDatasetReconciliation = true
            schedulePostSyncDatasetReconciliationIfNeeded()
            return
        }
        guard page.totalCount != totalMessageCount ||
                page.messageIDs != window.messageIDs else {
            postSyncValidationRetryCount = 0
            return
        }

        messageDatasetGeneration &+= 1
        if isLoadingMore {
            needsDatasetReconciliationAfterCurrentLoad = true
            needsPostSyncDatasetReconciliation = true
            return
        }

        let didReconcile = await reconcileWindowAfterDatasetMutation(
            window: window,
            shouldFollowLatestWindow: shouldFollowLatestWindow
        )
        guard !Task.isCancelled else { return }
        guard !didReconcile else {
            postSyncValidationRetryCount = 0
            return
        }

        needsPostSyncDatasetReconciliation = true
        if postSyncValidationRetryCount < maximumAutomaticPostSyncValidationRetryCount {
            postSyncValidationRetryCount += 1
            schedulePostSyncDatasetReconciliationIfNeeded()
        }
    }

    @discardableResult
    private func reloadHistoricalWindowClamped(
        _ window: MessageWindow,
        preferPendingConversationMessages: Bool,
        datasetRetryAttemptsRemaining: Int = 1
    ) async -> Bool {
        let loadGeneration = beginWindowLoad(
            intent: .range(window.startIndex..<window.endIndex)
        )
        let expectedDatasetGeneration = messageDatasetGeneration
        let loadedTotalCount = await loadTotalMessageCount(
            preferPendingConversationMessages: preferPendingConversationMessages
        )
        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return false
        }
        guard loadGeneration == windowLoadGeneration else { return false }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            guard datasetRetryAttemptsRemaining > 0 else {
                finishWindowLoadFailure(
                    operation: "historical window metadata",
                    description: "message dataset kept changing while loading"
                )
                return false
            }
            return await reloadHistoricalWindowClamped(
                window,
                preferPendingConversationMessages:
                    preferPendingConversationMessages || hasPendingInsertedMessagesInConversation,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining - 1
            )
        }
        guard let totalCount = loadedTotalCount else {
            finishWindowLoadFailure(
                operation: "dataset reconciliation metadata",
                description: "unable to fetch message count"
            )
            return false
        }

        let desiredWindowCount = max(1, window.endIndex - window.startIndex)
        let latestPossibleStart = max(0, totalCount - desiredWindowCount)
        let adjustedStartIndex = min(window.startIndex, latestPossibleStart)
        let adjustedEndIndex = min(
            totalCount,
            adjustedStartIndex + desiredWindowCount
        )
        return await loadWindow(
            startIndex: adjustedStartIndex,
            endIndex: adjustedEndIndex,
            preferPendingConversationMessages: preferPendingConversationMessages,
            generation: loadGeneration,
            datasetGeneration: expectedDatasetGeneration,
            datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining
        ) != nil
    }

    private func refreshedCachedMessageIDs(
        in notification: Notification,
        cachedMessageIDs: Set<NSManagedObjectID>
    ) -> Set<NSManagedObjectID> {
        var affectedMessageIDs = Set<NSManagedObjectID>()

        for object in contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message,
                  cachedMessageIDs.contains(message.objectID) else {
                continue
            }

            affectedMessageIDs.insert(message.objectID)
        }

        for object in contextObjects(
            forKeys: [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey],
            in: notification
        ) {
            guard let attachment = object as? Attachment,
                  let messageID = attachment.message?.objectID,
                  cachedMessageIDs.contains(messageID) else {
                continue
            }

            affectedMessageIDs.insert(messageID)
        }

        let changedPersonEmails = Set(contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        ).compactMap { object -> String? in
            guard let person = object as? Person else { return nil }
            let email = EmailNormalizer.normalize(person.email)
            return email.isEmpty ? nil : email
        })

        if !changedPersonEmails.isEmpty {
            for messageID in cachedMessageIDs {
                guard let row = resolveCachedRow(for: messageID),
                      row.matchesSenderEmail(in: changedPersonEmails) else {
                    continue
                }

                affectedMessageIDs.insert(messageID)
            }
        }

        return affectedMessageIDs
    }

    private func assessUncachedRefreshedMessages(
        in notification: Notification
    ) -> UncachedRefreshAssessment {
        var assessment = UncachedRefreshAssessment()

        for object in contextObjects(
            forKeys: [NSRefreshedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message else { continue }

            let cachedRow = resolvedRowsByID[message.objectID] ??
                resolvedRowsByAbsoluteIndex.values.first {
                    $0.objectID == message.objectID
                }
            guard cachedRow == nil else { continue }

            // A sibling-context merge does not retain changed property keys.
            // Delay ambiguous, off-window refreshes until count/sync
            // reconciliation instead of invalidating an in-flight initial load
            // for harmless changes such as marking old messages read.
            guard belongsToCurrentConversation(message) else { continue }

            if !isVisibleInChat(message) ||
                refreshedMessageCouldBelongInCurrentWindow(message) {
                assessment.orderedDatasetDidChange = true
            } else {
                assessment.needsCountReconciliation = true
            }
        }

        return assessment
    }

    private func refreshedMessageCouldBelongInCurrentWindow(
        _ message: Message
    ) -> Bool {
        guard let window = messageWindow,
              let firstMessageID = window.messageIDs.first,
              let lastMessageID = window.messageIDs.last,
              let firstRow = resolveCachedRow(for: firstMessageID),
              let lastRow = resolveCachedRow(for: lastMessageID) else {
            return false
        }

        if window.startIndex == 0,
           compareSortOrder(message, to: lastRow) != .orderedDescending {
            return true
        }
        if window.endIndex >= totalMessageCount,
           compareSortOrder(message, to: firstRow) != .orderedAscending {
            return true
        }
        return compareSortOrder(message, to: firstRow) != .orderedAscending &&
            compareSortOrder(message, to: lastRow) != .orderedDescending
    }

    private func compareSortOrder(
        _ message: Message,
        to row: ChatMessageRowModel
    ) -> ComparisonResult {
        if message.internalDate < row.internalDate {
            return .orderedAscending
        }
        if message.internalDate > row.internalDate {
            return .orderedDescending
        }
        return message.id.compare(row.id)
    }

    private func containsOrderedDatasetAffectingMessageUpdate(
        _ notification: Notification
    ) -> Bool {
        for object in contextObjects(
            forKeys: [NSUpdatedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message,
                  belongsToCurrentConversation(message) else {
                continue
            }

            let changedValues = message.changedValuesForCurrentEvent()
            let changedKeys = Set(changedValues.keys)
            if changedKeys.contains("conversation") ||
                changedKeys.contains("internalDate") {
                return true
            }
            if changedKeys.contains("labels") {
                guard let previousLabels = changedValues["labels"] as? NSSet else {
                    return true
                }

                let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
                let previousLabelIDs = Set(previousLabels.compactMap {
                    ($0 as? Label)?.id
                })
                guard previousLabelIDs.count == previousLabels.count else {
                    return true
                }

                let wasVisible = previousLabelIDs.isDisjoint(
                    with: excludedLabelIDs
                )
                if wasVisible != isVisibleInChat(message) {
                    return true
                }
            }
        }

        // Automatically merged sibling-context saves arrive as refreshed
        // objects with no property-key delta. Compare cached rows directly;
        // ambiguous uncached rows are classified separately so content-only
        // off-window updates do not invalidate the active fetch.
        for object in contextObjects(
            forKeys: [NSRefreshedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message else { continue }

            let cachedRow = resolvedRowsByID[message.objectID] ??
                resolvedRowsByAbsoluteIndex.values.first {
                    $0.objectID == message.objectID
                }
            let currentlyBelongs = belongsToCurrentConversation(message)

            guard currentlyBelongs || cachedRow != nil else { continue }
            guard let cachedRow else { continue }

            if cachedRow.conversationObjectID != message.conversation?.objectID ||
                cachedRow.internalDate != message.internalDate ||
                !isVisibleInChat(message) {
                return true
            }
        }

        return false
    }

    /// Type-check-only relevance scan for objectsDidChange payloads. Nothing
    /// here faults an object; the expensive relationship checks below only
    /// run for notifications that pass this.
    nonisolated static func isRelevantChatContextChange(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        let keys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSRefreshedObjectsKey,
            NSDeletedObjectsKey
        ]
        let personKeys: Set<String> = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]

        for key in keys {
            guard let objects = userInfo[key] as? Set<NSManagedObject> else { continue }
            let includesPersons = personKeys.contains(key)
            for object in objects {
                if object is Message || object is Attachment {
                    return true
                }
                if includesPersons, object is Person {
                    return true
                }
            }
        }
        return false
    }

    /// Resolved once (objectID-only fetch) so conversation membership checks
    /// compare objectIDs instead of faulting each inserted message's
    /// Conversation row for its UUID. Temporary IDs (optimistic unsaved
    /// conversations) are not cached — they change identity on save.
    private func currentConversationObjectID() -> NSManagedObjectID? {
        if let cachedConversationObjectID {
            return cachedConversationObjectID
        }
        guard let conversationUUID = UUID(uuidString: conversationId) else { return nil }

        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
        request.predicate = NSPredicate(format: "id == %@", conversationUUID as CVarArg)
        request.resultType = .managedObjectIDResultType
        request.fetchLimit = 1

        let objectID = (try? viewContext.fetch(request))?.first
        if let objectID, !objectID.isTemporaryID {
            cachedConversationObjectID = objectID
        }
        return objectID
    }

    /// Membership check that faults at most the message row: the destination
    /// objectID of the to-one relationship is available without firing the
    /// Conversation's own fault (the previous UUID comparison loaded the
    /// Conversation row for every inserted message in every merge).
    private func belongsToCurrentConversation(_ message: Message) -> Bool {
        let conversationObjectID = currentConversationObjectID()
        let conversationUUID = UUID(uuidString: conversationId)

        if let messageConversation = message.conversation {
            if messageConversation.objectID == conversationObjectID {
                return true
            }
            // A sibling-context merge can publish the relationship before
            // all required attributes on its destination are materialized.
            // Reading the nonoptional Swift property in that window traps
            // while bridging nil; optional KVC keeps the observer resilient.
            if let messageConversationID =
                messageConversation.value(forKey: "id") as? UUID,
               messageConversationID == conversationUUID {
                return true
            }
        }

        // Core Data may clear an inverse relationship before publishing the
        // deleted object in objectsDidChange. Its committed destination still
        // identifies which conversation's ordered dataset changed.
        if let committedConversation = message.committedValues(
            forKeys: ["conversation"]
        )["conversation"] as? Conversation {
            if committedConversation.objectID == conversationObjectID {
                return true
            }
            if let committedConversationID =
                committedConversation.value(forKey: "id") as? UUID,
               committedConversationID == conversationUUID {
                return true
            }
        }

        return false
    }

    private func hasVisibleInsertedMessageForCurrentConversation(in notification: Notification) -> Bool {
        contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .contains { object in
                guard let message = object as? Message,
                      belongsToCurrentConversation(message) else {
                    return false
                }

                return isVisibleInChat(message)
            }
    }

    private func visibleInsertedMessagesSortStrictlyAfterWindow(
        in notification: Notification,
        window: MessageWindow
    ) -> Bool {
        guard let boundaryMessageID = window.messageIDs.last,
              let boundaryDate = resolveCachedRow(
                for: boundaryMessageID
              )?.internalDate else {
            return false
        }

        let insertedMessages = contextObjects(
            forKeys: [NSInsertedObjectsKey],
            in: notification
        ).compactMap { object -> Message? in
            guard let message = object as? Message,
                  belongsToCurrentConversation(message),
                  isVisibleInChat(message) else {
                return nil
            }
            return message
        }

        return !insertedMessages.isEmpty &&
            insertedMessages.allSatisfy { $0.internalDate > boundaryDate }
    }

    private func estimatedTotalCountAfterLocalMessageMutation(in notification: Notification) -> Int {
        let insertedCount = visibleInsertedMessageCountForCurrentConversation(in: notification)
        let deletedCount = visibleDeletedMessageCountForCurrentConversation(in: notification)

        return max(0, totalMessageCount + insertedCount - deletedCount)
    }

    private func visibleInsertedMessageCountForCurrentConversation(in notification: Notification) -> Int {
        visibleInsertedMessageIDsForCurrentConversation(in: notification).count
    }

    private func visibleDeletedMessageCountForCurrentConversation(
        in notification: Notification
    ) -> Int {
        contextObjects(forKeys: [NSDeletedObjectsKey], in: notification)
            .compactMap { $0 as? Message }
            .filter {
                belongsToCurrentConversation($0) &&
                    wasVisibleInChatBeforeDeletion($0)
            }
            .count
    }

    private func wasVisibleInChatBeforeDeletion(_ message: Message) -> Bool {
        if let previousLabels = message.committedValues(
            forKeys: ["labels"]
        )["labels"] as? NSSet {
            let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
            let previousLabelIDs = Set(previousLabels.compactMap {
                ($0 as? Label)?.id
            })
            if previousLabelIDs.count == previousLabels.count {
                return previousLabelIDs.isDisjoint(with: excludedLabelIDs)
            }
        }

        return isVisibleInChat(message)
    }

    private func visibleInsertedMessageIDsForCurrentConversation(
        in notification: Notification
    ) -> [NSManagedObjectID] {
        contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .compactMap { object -> NSManagedObjectID? in
                guard let message = object as? Message,
                      !message.objectID.isTemporaryID,
                      belongsToCurrentConversation(message),
                      isVisibleInChat(message) else {
                    return nil
                }

                return message.objectID
            }
            .sorted {
                $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
            }
    }

    private func newestVisibleInsertedMessageIDsForCurrentConversation(
        in notification: Notification
    ) -> [NSManagedObjectID] {
        let latestWindowDate: Date?
        if let latestWindowMessageID = messageWindow?.messageIDs.last {
            guard let date = resolveCachedRow(for: latestWindowMessageID)?.internalDate else {
                return []
            }
            latestWindowDate = date
        } else {
            latestWindowDate = nil
        }

        return contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .compactMap { object -> NSManagedObjectID? in
                guard let message = object as? Message,
                      !message.objectID.isTemporaryID,
                      belongsToCurrentConversation(message),
                      isVisibleInChat(message),
                      latestWindowDate.map({ message.internalDate > $0 }) ?? true else {
                    return nil
                }

                return message.objectID
            }
            .sorted {
                $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
            }
    }

    private func resolvePendingInsertedMessageEvents() {
        guard !pendingInsertedMessageEvents.isEmpty else { return }

        let latestWindowMessageIDs: Set<NSManagedObjectID>
        if isShowingLatestWindow, let messageWindow {
            latestWindowMessageIDs = Set(messageWindow.messageIDs)
        } else {
            latestWindowMessageIDs = []
        }

        let events = pendingInsertedMessageEvents
        pendingInsertedMessageEvents.removeAll()
        let layoutID = UUID()
        latestWindowLayoutID = layoutID

        for event in events {
            refreshedInsertedMessageEvents.send(
                VirtualScrollInsertedMessageRefresh(
                    eventID: event.id,
                    layoutID: layoutID,
                    messageIDsInLatestWindow: event.messageIDs.filter {
                        latestWindowMessageIDs.contains($0)
                    }
                )
            )
        }
    }

    private func isVisibleInChat(_ message: Message) -> Bool {
        let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
        let labelIDs = message.labels?.map(\.id) ?? []
        return labelIDs.allSatisfy { !excludedLabelIDs.contains($0) }
    }

    private func contextObjects(
        forKeys keys: [String],
        in notification: Notification
    ) -> Set<NSManagedObject> {
        keys.reduce(into: Set<NSManagedObject>()) { result, key in
            let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
            result.formUnion(objects)
        }
    }

    private func setMessageWindow(_ window: MessageWindow) {
        messageWindow = window
        resolvedRowsByAbsoluteIndex.removeAll()

        let allowedIDs = Set(window.messageIDs)
        resolvedRowsByID = resolvedRowsByID.filter { allowedIDs.contains($0.key) }
    }

    private func invalidateCachedRows(for objectIDs: Set<NSManagedObjectID>) {
        guard !objectIDs.isEmpty else { return }

        for objectID in objectIDs {
            resolvedRowsByID.removeValue(forKey: objectID)
        }

        resolvedRowsByAbsoluteIndex = resolvedRowsByAbsoluteIndex.filter { _, row in
            !objectIDs.contains(row.objectID)
        }
    }

    // The original bug was caused by fetching `Message` instances in a background
    // context and then storing those managed objects on `@MainActor` state. We now
    // re-resolve background-fetched object IDs on the viewContext before mapping
    // them into lightweight row snapshots for SwiftUI.
    private func resolveRowsOnViewContextThrowing(
        for messageIDs: [NSManagedObjectID]
    ) throws -> [ChatMessageRowModel] {
        guard !messageIDs.isEmpty else { return [] }

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = NSPredicate(format: "SELF IN %@", messageIDs)
        request.fetchBatchSize = messageIDs.count
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]

        let fetchedMessages = try viewContext.fetch(request)
        let resolvedRows: [NSManagedObjectID: ChatMessageRowModel] = Dictionary(
            uniqueKeysWithValues: fetchedMessages.compactMap { message in
                guard !message.isDeleted else { return nil }
                return (message.objectID, ChatMessageRowModelMapper.map(message))
            }
        )

        for objectID in messageIDs {
            if let row = resolvedRows[objectID] {
                resolvedRowsByID[objectID] = row
            } else {
                resolvedRowsByID.removeValue(forKey: objectID)
            }
        }

        return messageIDs.compactMap { resolvedRows[$0] }
    }

    func row(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        guard let window = messageWindow,
              window.contains(index: index) else {
            return nil
        }

        let relativeIndex = index - window.startIndex
        guard relativeIndex >= 0, relativeIndex < window.messageIDs.count else {
            return nil
        }

        return resolveCachedRow(for: window.messageIDs[relativeIndex])
    }

    func rowForGrouping(atAbsoluteIndex index: Int) -> ChatMessageRowModel? {
        if let row = row(atAbsoluteIndex: index) {
            return row
        }

        guard index >= 0, index < totalMessageCount else { return nil }
        if let cached = resolvedRowsByAbsoluteIndex[index] {
            return cached
        }
        guard let conversationUUID = UUID(uuidString: conversationId) else { return nil }

        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        request.sortDescriptors = Self.messageSortDescriptors
        request.fetchOffset = index
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.includesPendingChanges = true
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person", "attachments"]

        guard let message = try? viewContext.fetch(request).first,
              !message.isDeleted else {
            return nil
        }

        let row = ChatMessageRowModelMapper.map(message)
        resolvedRowsByID[message.objectID] = row
        resolvedRowsByAbsoluteIndex[index] = row
        return row
    }

    private func resolveCachedRows(for messageIDs: [NSManagedObjectID]) -> [ChatMessageRowModel] {
        messageIDs.compactMap(resolveCachedRow)
    }

    private func resolveCachedRow(for objectID: NSManagedObjectID) -> ChatMessageRowModel? {
        if let cached = resolvedRowsByID[objectID] {
            return cached
        }

        if let registered = viewContext.registeredObject(for: objectID) as? Message,
           !registered.isDeleted {
            let row = ChatMessageRowModelMapper.map(registered)
            resolvedRowsByID[objectID] = row
            return row
        }

        do {
            guard let resolved = try viewContext.existingObject(with: objectID) as? Message,
                  !resolved.isDeleted else {
                resolvedRowsByID.removeValue(forKey: objectID)
                return nil
            }

            let row = ChatMessageRowModelMapper.map(resolved)
            resolvedRowsByID[objectID] = row
            return row
        } catch {
            resolvedRowsByID.removeValue(forKey: objectID)
            return nil
        }
    }

    nonisolated static func loadMessagePage(
        conversationId: String,
        range: Range<Int>,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            do {
                let messageIDs: [NSManagedObjectID]
                if range.isEmpty {
                    messageIDs = []
                } else {
                    let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
                    request.predicate = safePredicate
                    request.sortDescriptors = messageSortDescriptors
                    request.fetchOffset = range.lowerBound
                    request.fetchLimit = range.count
                    request.fetchBatchSize = 20
                    request.includesPendingChanges = false
                    request.resultType = .managedObjectIDResultType
                    messageIDs = try context.fetch(request)
                }

                // Keep count() on the background context so window sizing stays cheap and
                // the main actor only resolves the IDs it actually needs to render.
                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                countRequest.predicate = safePredicate
                countRequest.includesPendingChanges = false
                let totalCount = try context.count(for: countRequest)

                return VirtualScrollMessagePage(
                    messageIDs: messageIDs,
                    totalCount: totalCount
                )
            } catch {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 0,
                    fetchErrorDescription: error.localizedDescription
                )
            }
        }
    }

    nonisolated private static func loadPendingMessagePage(
        conversationId: String,
        range: Range<Int>,
        in context: NSManagedObjectContext
    ) async -> VirtualScrollMessagePage {
        guard let conversationUUID = UUID(uuidString: conversationId) else {
            return VirtualScrollMessagePage(messageIDs: [], totalCount: 0)
        }

        let predicate = MessagePredicates.visibleInChat(conversationId: conversationUUID)
        nonisolated(unsafe) let safePredicate = predicate

        return await context.perform {
            do {
                let messages: [Message]
                if range.isEmpty {
                    messages = []
                } else {
                    let request = NSFetchRequest<Message>(entityName: "Message")
                    request.predicate = safePredicate
                    request.sortDescriptors = messageSortDescriptors
                    request.fetchOffset = range.lowerBound
                    request.fetchLimit = range.count
                    request.fetchBatchSize = 20
                    request.includesPendingChanges = true
                    messages = try context.fetch(request)
                }

                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                countRequest.predicate = safePredicate
                countRequest.includesPendingChanges = true
                let totalCount = try context.count(for: countRequest)

                return VirtualScrollMessagePage(
                    messageIDs: messages.map(\.objectID),
                    totalCount: totalCount
                )
            } catch {
                return VirtualScrollMessagePage(
                    messageIDs: [],
                    totalCount: 0,
                    fetchErrorDescription: error.localizedDescription
                )
            }
        }
    }

    nonisolated private static var messageSortDescriptors: [NSSortDescriptor] {
        [
            NSSortDescriptor(key: "internalDate", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
    }
}

private extension VirtualScrollState.InitialWindowPosition {
    var diagnosticName: String {
        switch self {
        case .beginning:
            return "beginning"
        case .end:
            return "end"
        }
    }
}

private extension ChatMessageRowModel {
    func matchesSenderEmail(in emails: Set<String>) -> Bool {
        [
            senderInfoEmail,
            effectiveSenderEmail,
            senderEmail
        ]
        .compactMap { $0 }
        .map(EmailNormalizer.normalize)
        .contains { emails.contains($0) }
    }
}
