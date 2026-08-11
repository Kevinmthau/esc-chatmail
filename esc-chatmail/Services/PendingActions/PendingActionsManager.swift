import Foundation
import CoreData

// MARK: - Pending Actions Manager

private enum PendingActionProcessingOutcome: Equatable {
    case completed
    case authenticationError
    case credentialsRevoked
    case quotaExhausted
    case cancelled
    case skipped
}

struct PendingActionLifecycleHooks: Sendable {
    var scheduledProcessingDidWaitForRun: (@Sendable () async -> Void)? = nil
    var scheduledProcessingWillCreateInitialContext: (@Sendable () async -> Void)? = nil
    var scheduledProcessingDidReleaseRun: (@Sendable () async -> Void)? = nil
    var retryMutationDidResetAction: (@Sendable (SyncRun) async -> Void)? = nil
}

/// Manages a persistent queue of pending actions that need to be synced to Gmail.
/// Actions are stored in CoreData and processed when network is available.
///
/// The implementation is split across multiple files:
/// - `PendingActionsManagerProtocol.swift`: Protocol definition
/// - `PendingActionProcessor.swift`: Action execution and retry logic
/// - `PendingActionQueries.swift`: Query methods (count, hasPending, cancel)
///
/// Dependencies:
/// - NetworkMonitor: Handles connectivity detection
/// - ActionExecutor: Handles action execution against Gmail API
/// - PendingActionsManager: Coordinates queuing and processing
actor PendingActionsManager: PendingActionsManagerProtocol {
    static let shared = PendingActionsManager()

    // MARK: - Dependencies (internal for extensions)

    let coreDataStack: CoreDataStack
    let actionExecutor: ActionExecutorProtocol
    let networkMonitor: NetworkMonitorProtocol
    let syncRunCoordinator: SyncRunCoordinator
    let lifecycleHooks: PendingActionLifecycleHooks
    private let quotaRetryBaseDelay: TimeInterval
    private let quotaRetryMaximumDelay: TimeInterval
    private let quotaRetrySleeper: @Sendable (TimeInterval) async -> Bool

    // MARK: - Configuration (internal for extensions)

    let maxRetries = 5
    let baseRetryDelay: TimeInterval = 2.0
    let processingStaleInterval: TimeInterval = 10 * 60

    // MARK: - State

    private var isProcessing = false
    private var isInitialized = false
    private var pendingProcessTask: Task<Void, Never>?
    private var quotaRetryTask: Task<Void, Never>?
    private var quotaRetryTaskID: UUID?
    private var quotaRetryAttempt = 0
    private var activeProcessingOutcome: PendingActionProcessingOutcome = .completed
    private var processingWasRequested = false

    // MARK: - Initialization

    /// Production initializer
    private init() {
        self.coreDataStack = CoreDataStack.shared
        self.actionExecutor = GmailActionExecutor()
        self.networkMonitor = AppNetworkMonitor.shared
        self.syncRunCoordinator = .shared
        self.lifecycleHooks = PendingActionLifecycleHooks()
        self.quotaRetryBaseDelay = 15 * 60
        self.quotaRetryMaximumDelay = 60 * 60
        self.quotaRetrySleeper = { delay in
            await Task.sleepUnlessCancelled(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
        }
    }

    /// Testable initializer with dependency injection
    init(
        coreDataStack: CoreDataStack,
        actionExecutor: ActionExecutorProtocol = GmailActionExecutor(),
        networkMonitor: NetworkMonitorProtocol = AppNetworkMonitor.shared,
        syncRunCoordinator: SyncRunCoordinator = .shared,
        lifecycleHooks: PendingActionLifecycleHooks = PendingActionLifecycleHooks(),
        quotaRetryBaseDelay: TimeInterval = 15 * 60,
        quotaRetryMaximumDelay: TimeInterval = 60 * 60,
        quotaRetrySleeper: @escaping @Sendable (TimeInterval) async -> Bool = { delay in
            await Task.sleepUnlessCancelled(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
        }
    ) {
        self.coreDataStack = coreDataStack
        self.actionExecutor = actionExecutor
        self.networkMonitor = networkMonitor
        self.syncRunCoordinator = syncRunCoordinator
        self.lifecycleHooks = lifecycleHooks
        self.quotaRetryBaseDelay = quotaRetryBaseDelay
        self.quotaRetryMaximumDelay = quotaRetryMaximumDelay
        self.quotaRetrySleeper = quotaRetrySleeper
    }

    /// Sets up network monitoring on first use
    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        Task { [weak self] in
            await self?.recoverStuckProcessingActions()
        }

        networkMonitor.onConnectivityChange = { [weak self] isConnected in
            guard isConnected else { return }
            Task { [weak self] in
                await self?.scheduleProcessing()
            }
        }
        networkMonitor.start()
    }

    /// Schedules processing with deduplication to prevent multiple concurrent processing tasks
    /// during network flaps (rapid connect/disconnect cycles)
    private func scheduleProcessing() {
        // Quota exhaustion gates every automatic request until the existing
        // bounded retry expires. Enqueues are already durable; remember their
        // signal without cancelling the timer or starting an immediate scan.
        guard quotaRetryTask == nil else {
            processingWasRequested = true
            return
        }

        // Coalesce duplicate work without discarding the signal. In particular,
        // an enqueue may land after a run releases the sync boundary but before
        // its quota outcome clears pendingProcessTask.
        guard pendingProcessTask == nil, !isProcessing else {
            processingWasRequested = true
            return
        }

        processingWasRequested = false
        pendingProcessTask = Task { [weak self] in
            guard let self = self else { return }
            let outcome = await self.processAllPendingActionsWithOutcome()
            await self.clearPendingTask(after: outcome)
        }
    }

    private func clearPendingTask(after outcome: PendingActionProcessingOutcome) async {
        // Account-wide failures leave the row pending intentionally. Auth
        // failures wait for authentication recovery instead of immediately
        // re-scanning a queue that cannot succeed. Quota exhaustion retains
        // concurrent enqueue signals behind one bounded exponential-backoff
        // wake-up. A run cancelled by account teardown is
        // different: autonomous processing carries no old-account identifiers,
        // so it may wait through teardown and scan the current store under a
        // fresh run afterward.
        switch outcome {
        case .authenticationError, .credentialsRevoked:
            pendingProcessTask = nil
            processingWasRequested = false
            resetQuotaRetryBackoff()
            return
        case .quotaExhausted:
            pendingProcessTask = nil
            scheduleQuotaRetry()
            return
        case .skipped:
            pendingProcessTask = nil
            _ = scheduleRequestedFollowUpIfNeeded()
            return
        case .completed:
            resetQuotaRetryBackoff()
        case .cancelled:
            break
        }
        guard networkMonitor.isConnected else {
            pendingProcessTask = nil
            processingWasRequested = false
            return
        }
        guard let syncRun = await acquirePendingActionRun() else {
            pendingProcessTask = nil
            processingWasRequested = false
            return
        }
        let hasActionsNeedingProcessing = await hasActionsNeedingProcessing(
            within: syncRun
        )
        await syncRunCoordinator.endRun(syncRun)

        pendingProcessTask = nil
        guard hasActionsNeedingProcessing || processingWasRequested else { return }
        scheduleProcessing()
    }

    @discardableResult
    private func scheduleRequestedFollowUpIfNeeded() -> Bool {
        guard processingWasRequested else { return false }
        processingWasRequested = false
        guard networkMonitor.isConnected else { return false }
        scheduleProcessing()
        return true
    }

    private func scheduleQuotaRetry() {
        // Start the quota delay even if connectivity dropped while the failed
        // run was finishing. A reconnect before expiry must remain gated; if
        // the delay expires offline, processing can resume on the next
        // connectivity callback.
        guard quotaRetryTask == nil else { return }

        let delay = Self.quotaRetryDelay(
            forAttempt: quotaRetryAttempt,
            baseDelay: quotaRetryBaseDelay,
            maximumDelay: quotaRetryMaximumDelay
        )
        quotaRetryAttempt = min(quotaRetryAttempt + 1, 63)

        let taskID = UUID()
        let sleeper = quotaRetrySleeper
        quotaRetryTaskID = taskID
        quotaRetryTask = Task { [weak self] in
            guard await sleeper(delay) else { return }
            await self?.quotaRetryDelayElapsed(taskID: taskID)
        }

        Log.info("Scheduled pending-action quota retry in \(delay) seconds", category: .sync)
    }

    private func quotaRetryDelayElapsed(taskID: UUID) {
        guard quotaRetryTaskID == taskID else { return }
        quotaRetryTask = nil
        quotaRetryTaskID = nil
        guard networkMonitor.isConnected else { return }
        scheduleProcessing()
    }

    private func cancelQuotaRetryTask() {
        quotaRetryTask?.cancel()
        quotaRetryTask = nil
        quotaRetryTaskID = nil
    }

    private func resetQuotaRetryBackoff() {
        cancelQuotaRetryTask()
        quotaRetryAttempt = 0
    }

    /// Retires quota scheduling owned by the account being torn down. The
    /// manager is process-wide, so carrying this attempt counter into the next
    /// authenticated account could make that account's first retry inherit an
    /// unrelated hour-long backoff.
    func resetQuotaRetryStateForAccountTransition() {
        resetQuotaRetryBackoff()
    }

    nonisolated static func quotaRetryDelay(
        forAttempt attempt: Int,
        baseDelay: TimeInterval,
        maximumDelay: TimeInterval
    ) -> TimeInterval {
        guard baseDelay > 0, maximumDelay > 0 else { return 0 }
        let exponent = min(max(attempt, 0), 63)
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }

    /// Waits for automatic processing and any follow-up cycle to settle.
    /// Primarily useful for deterministic lifecycle tests.
    func waitUntilScheduledProcessingIsIdle() async {
        while let pendingProcessTask {
            await pendingProcessTask.value
        }
    }

    func acquirePendingActionRun() async -> SyncRun? {
        while !Task.isCancelled {
            if let syncRun = await syncRunCoordinator.beginRun(kind: .pendingActions) {
                return syncRun
            }

            Log.debug("Pending action processing waiting for the account boundary", category: .sync)
            await syncRunCoordinator.waitUntilIdle()
        }

        return nil
    }

    private func acquirePendingActionRunTask() async -> SyncRunTask? {
        while !Task.isCancelled {
            if let syncRunTask = await syncRunCoordinator.beginRunWithTask(
                kind: .pendingActions,
                taskBuilder: { [weak self] syncRun in
                    Task<Void, Error> {
                        guard let self else { return }
                        await self.performPendingActionRun(within: syncRun)
                    }
                }
            ) {
                return syncRunTask
            }

            Log.debug("Pending action processing waiting for the account boundary", category: .sync)
            await lifecycleHooks.scheduledProcessingDidWaitForRun?()
            await syncRunCoordinator.waitUntilIdle()
        }

        return nil
    }

    public func stopMonitoring() {
        networkMonitor.stop()
        cancelQuotaRetryTask()
        isInitialized = false
    }

    // MARK: - Queue Actions

    public func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]? = nil
    ) async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            Log.info("Discarding pending action requested during an account transition", category: .sync)
            return
        }

        await queueAction(
            type: type,
            messageId: messageId,
            payload: payload,
            accountWorkRequest: accountWorkRequest
        )
    }

    /// Internal request-stamped entry point keeps the generation capture
    /// separate from acquisition so stale-queue behavior can be exercised
    /// deterministically in tests.
    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]? = nil,
        accountWorkRequest: AccountWorkRequest
    ) async {
        ensureInitialized()

        guard let syncRun = await syncRunCoordinator.acquireRun(
            kind: .pendingActions,
            for: accountWorkRequest
        ) else {
            Log.info("Discarding pending action invalidated by an account transition", category: .sync)
            return
        }

        let saveSucceeded = await persistAction(
            type: type,
            messageId: messageId,
            payload: payload
        )
        await syncRunCoordinator.endRun(syncRun)
        finishSingleActionEnqueue(
            saveSucceeded: saveSucceeded,
            type: type,
            messageId: messageId
        )
    }

    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]?,
        within syncRun: SyncRun
    ) async {
        ensureInitialized()

        guard await syncRunCoordinator.isActiveRun(syncRun) else {
            Log.error("Refusing pending action without its active account-work run", category: .sync)
            return
        }

        let saveSucceeded = await persistAction(
            type: type,
            messageId: messageId,
            payload: payload
        )
        finishSingleActionEnqueue(
            saveSucceeded: saveSucceeded,
            type: type,
            messageId: messageId
        )
    }

    public func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String]
    ) async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            Log.info("Discarding conversation action requested during an account transition", category: .sync)
            return
        }

        await queueConversationAction(
            type: type,
            sourceConversationId: sourceConversationId,
            messageIds: messageIds,
            accountWorkRequest: accountWorkRequest
        )
    }

    /// See `queueAction(...accountWorkRequest:)` for why the request stamp is
    /// passed explicitly to the implementation.
    func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String],
        accountWorkRequest: AccountWorkRequest
    ) async {
        ensureInitialized()

        guard let syncRun = await syncRunCoordinator.acquireRun(
            kind: .pendingActions,
            for: accountWorkRequest
        ) else {
            Log.info("Discarding conversation action invalidated by an account transition", category: .sync)
            return
        }

        let saveSucceeded = await persistConversationAction(
            type: type,
            sourceConversationId: sourceConversationId,
            messageIds: messageIds
        )
        await syncRunCoordinator.endRun(syncRun)
        finishConversationActionEnqueue(
            saveSucceeded: saveSucceeded,
            type: type,
            sourceConversationId: sourceConversationId
        )
    }

    func queueConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String],
        within syncRun: SyncRun
    ) async {
        ensureInitialized()

        guard await syncRunCoordinator.isActiveRun(syncRun) else {
            Log.error("Refusing conversation action without its active account-work run", category: .sync)
            return
        }

        let saveSucceeded = await persistConversationAction(
            type: type,
            sourceConversationId: sourceConversationId,
            messageIds: messageIds
        )
        finishConversationActionEnqueue(
            saveSucceeded: saveSucceeded,
            type: type,
            sourceConversationId: sourceConversationId
        )
    }

    private func persistAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]?
    ) async -> Bool {
        let context = coreDataStack.viewContext
        return await context.perform {
            self.createPendingAction(
                in: context,
                type: type,
                messageId: messageId,
                payload: payload
            )
            return context.saveOrLog(operation: "queue pending action: \(type.rawValue)")
        }
    }

    private func persistConversationAction(
        type: PendingAction.ActionType,
        sourceConversationId: UUID,
        messageIds: [String]
    ) async -> Bool {
        // sourceConversationId is metadata-only and stored for tracing/UI context.
        // Execution uses the payload message IDs.
        Log.info("Queueing \(type.rawValue) for \(messageIds.count) messages", category: .sync)

        let context = coreDataStack.viewContext
        let payload: [String: Any] = ["messageIds": messageIds]
        return await context.perform {
            self.createPendingAction(
                in: context,
                type: type,
                sourceConversationId: sourceConversationId,
                payload: payload
            )
            return context.saveOrLog(operation: "queue conversation action: \(type.rawValue)")
        }
    }

    private func finishSingleActionEnqueue(
        saveSucceeded: Bool,
        type: PendingAction.ActionType,
        messageId: String
    ) {
        // Only process if save succeeded - prevents processing stale/incomplete actions.
        // Remote processing is scheduled so callers return after durable enqueue.
        if saveSucceeded && networkMonitor.isConnected {
            scheduleProcessing()
        } else if !saveSucceeded {
            Log.error("Failed to save pending action \(type.rawValue) for message \(messageId) - action will not be queued", category: .sync)
        }
    }

    private func finishConversationActionEnqueue(
        saveSucceeded: Bool,
        type: PendingAction.ActionType,
        sourceConversationId: UUID
    ) {
        // Only process if save succeeded - prevents processing stale/incomplete actions.
        // Remote processing is scheduled so callers return after durable enqueue.
        if saveSucceeded && networkMonitor.isConnected {
            scheduleProcessing()
        } else if !saveSucceeded {
            Log.error("Failed to save conversation action \(type.rawValue) for conversation \(sourceConversationId) - action will not be queued", category: .sync)
        }
    }

    private nonisolated func createPendingAction(
        in context: NSManagedObjectContext,
        type: PendingAction.ActionType,
        messageId: String? = nil,
        sourceConversationId: UUID? = nil,
        payload: [String: Any]? = nil
    ) {
        let action = PendingAction(context: context)
        action.setValue(UUID(), forKey: "id")
        action.setValue(type.rawValue, forKey: "actionType")
        action.setValue(messageId, forKey: "messageId")
        action.setValue(sourceConversationId, forKey: "conversationId")
        action.setValue(Date(), forKey: "createdAt")
        action.setValue("pending", forKey: "status")
        action.setValue(Int16(0), forKey: "retryCount")

        if let payload = payload,
           let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            action.setValue(payloadString, forKey: "payload")
        }
    }

    // MARK: - Process Actions

    public func processAllPendingActions() async {
        // A direct request that races a quota-failed scheduled run observes the
        // same gate as an enqueue. Keep its signal for the already scheduled
        // retry instead of bypassing backoff with an immediate rescan.
        guard quotaRetryTask == nil else {
            processingWasRequested = true
            return
        }

        guard pendingProcessTask == nil, !isProcessing else {
            processingWasRequested = true
            return
        }
        let outcome = await processAllPendingActionsWithOutcome()
        switch outcome {
        case .authenticationError, .credentialsRevoked:
            processingWasRequested = false
            resetQuotaRetryBackoff()
        case .quotaExhausted:
            scheduleQuotaRetry()
        case .completed:
            resetQuotaRetryBackoff()
            _ = scheduleRequestedFollowUpIfNeeded()
        case .cancelled, .skipped:
            _ = scheduleRequestedFollowUpIfNeeded()
        }
    }

    private func processAllPendingActionsWithOutcome() async -> PendingActionProcessingOutcome {
        ensureInitialized()

        guard !isProcessing else { return .skipped }
        guard networkMonitor.isConnected else { return .completed }

        isProcessing = true
        defer { isProcessing = false }
        activeProcessingOutcome = .completed

        guard let syncRunTask = await acquirePendingActionRunTask() else {
            return .cancelled
        }

        do {
            try await syncRunTask.task.value
        } catch is CancellationError {
            activeProcessingOutcome = .cancelled
        } catch {
            Log.error("Pending action run ended unexpectedly", category: .sync, error: error)
            activeProcessingOutcome = .cancelled
        }

        await syncRunCoordinator.endRun(syncRunTask.run)
        await lifecycleHooks.scheduledProcessingDidReleaseRun?()
        return activeProcessingOutcome
    }

    private func performPendingActionRun(within syncRun: SyncRun) async {
        guard await syncRunCoordinator.isActiveRun(syncRun) else {
            activeProcessingOutcome = .cancelled
            return
        }

        // This hook sits immediately before the first context creation/fetch in
        // the scheduled scanner. It lets lifecycle tests prove that this exact
        // scanner, rather than initialization recovery, crossed quiescence.
        await lifecycleHooks.scheduledProcessingWillCreateInitialContext?()

        guard await hasActionsNeedingProcessing(within: syncRun) else {
            return
        }

        _ = await recoverStuckProcessingActions(within: syncRun)

        guard networkMonitor.isConnected, !Task.isCancelled else {
            activeProcessingOutcome = Task.isCancelled ? .cancelled : .completed
            return
        }

        let context = coreDataStack.newBackgroundContext()

        // Process actions one by one (uses extension methods). Stops on
        // cancellation so a cancelled sync task doesn't burn through the
        // remaining queue with backoff delays skipped, and when an action
        // reports an account-scoped failure (authentication, revoked
        // credentials, or quota exhaustion) that would fail every remaining
        // action identically.
        while !Task.isCancelled, let action = await fetchNextPendingAction(context: context) {
            guard !Task.isCancelled else {
                activeProcessingOutcome = .cancelled
                break
            }

            switch await processAction(action, context: context) {
            case .continueRun:
                continue
            case .stopRun(.authenticationError):
                activeProcessingOutcome = .authenticationError
            case .stopRun(.credentialsRevoked):
                activeProcessingOutcome = .credentialsRevoked
            case .stopRun(.quotaExhausted):
                activeProcessingOutcome = .quotaExhausted
            case .stopRun(.cancelled):
                activeProcessingOutcome = .cancelled
            }
            break
        }

        if Task.isCancelled {
            activeProcessingOutcome = .cancelled
        }

        await cleanupCompletedActions(context: context)
    }
}
