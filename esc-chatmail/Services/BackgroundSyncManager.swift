import Foundation
import BackgroundTasks
import CoreData
import os

enum BackgroundSyncRetryAction: Equatable {
    case none
    case failureBackoff
    case catchUp
}

struct BackgroundSyncCompletionDisposition: Equatable {
    let historyIdToStore: String?
    let continuationState: BackgroundSyncContinuationState?
    let retryAction: BackgroundSyncRetryAction
    let shouldResetRetryState: Bool
}

/// Main orchestrator for background sync operations
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    static let catchUpRetryDelay: TimeInterval = 5 * 60

    // MARK: - Components

    private let taskScheduler: BackgroundTaskScheduler
    private let stateManager: BackgroundSyncStateManager
    private let errorHandler = BackgroundSyncErrorHandler()
    private let messageProcessor: BackgroundMessageProcessor
    private let authSessionProvider: @MainActor @Sendable () -> AuthSession
    private let apiClientProvider: @MainActor @Sendable () -> GmailAPIClientProtocol

    init(
        taskScheduler: BackgroundTaskScheduler = .shared,
        coreDataStack: CoreDataStack = .shared,
        authSessionProvider: @escaping @MainActor @Sendable () -> AuthSession = { AuthSession.shared },
        apiClientProvider: @escaping @MainActor @Sendable () -> GmailAPIClientProtocol = { GmailAPIClient.shared },
        syncCoordinatorProvider: @escaping @MainActor @Sendable () -> BackgroundSyncMessageCoordinating = {
            SyncEngine.shared
        }
    ) {
        self.taskScheduler = taskScheduler
        self.stateManager = BackgroundSyncStateManager(coreDataStack: coreDataStack)
        self.messageProcessor = BackgroundMessageProcessor(
            coreDataStack: coreDataStack,
            apiClientProvider: apiClientProvider,
            syncCoordinatorProvider: syncCoordinatorProvider
        )
        self.authSessionProvider = authSessionProvider
        self.apiClientProvider = apiClientProvider

        setupTaskHandlers()
    }

    private func setupTaskHandlers() {
        taskScheduler.onAppRefresh = { [weak self] task in
            self?.handleAppRefresh(task: task)
        }
        taskScheduler.onProcessing = { [weak self] task in
            self?.handleProcessing(task: task)
        }
    }

    // MARK: - Public API

    func registerBackgroundTasks() {
        taskScheduler.registerBackgroundTasks()
    }

    func scheduleAppRefresh() {
        taskScheduler.scheduleAppRefresh()
    }

    func scheduleProcessingTask() {
        taskScheduler.scheduleProcessingTask()
    }

    // MARK: - Task Handlers

    private func handleAppRefresh(task: BGAppRefreshTask) {
        taskScheduler.scheduleAppRefresh()
        runBackgroundTask(task, isProcessingTask: false)
    }

    private func handleProcessing(task: BGProcessingTask) {
        taskScheduler.scheduleProcessingTask()
        runBackgroundTask(task, isProcessingTask: true)
    }

    /// Shared implementation for both app-refresh and processing background tasks.
    /// Uses an atomic flag to ensure `setTaskCompleted` is called exactly once,
    /// preventing a race between normal completion and the expiration handler.
    private func runBackgroundTask(_ task: BGTask, isProcessingTask: Bool) {
        let completed = OSAllocatedUnfairLock(initialState: false)

        let completeOnce: (Bool) -> Void = { success in
            let alreadyCompleted = completed.withLock { done -> Bool in
                if done { return true }
                done = true
                return false
            }
            guard !alreadyCompleted else { return }
            task.setTaskCompleted(success: success)
        }

        let backgroundTask = Task { [weak self] in
            guard let self = self else {
                completeOnce(false)
                return
            }
            let success = await self.performDeltaSync(isProcessingTask: isProcessingTask)
            completeOnce(success)
        }

        task.expirationHandler = {
            backgroundTask.cancel()
            completeOnce(false)
        }
    }

    // MARK: - Sync Orchestration

    private func performDeltaSync(isProcessingTask: Bool) async -> Bool {
        do {
            let authSession = await MainActor.run { authSessionProvider() }
            _ = try await authSession.withFreshToken()
            let currentAccountEmail = await MainActor.run { authSession.userEmail }
            let historyId = await stateManager.getStoredHistoryId()

            if let continuationState = stateManager.getContinuationState() {
                if !continuationState.isCompatible(
                    storedHistoryId: historyId,
                    currentAccountEmail: currentAccountEmail
                ) {
                    stateManager.clearContinuationState()
                    Log.warning(
                        "Cleared stale background sync continuation state because the stored account or history cursor changed",
                        category: .background
                    )
                } else {
                    switch continuationState.mode {
                    case .history:
                        guard let startHistoryId = continuationState.startHistoryId else {
                            stateManager.clearContinuationState()
                            Log.warning("Cleared invalid background history continuation state", category: .background)
                            break
                        }

                        return await performHistorySync(
                            startHistoryId: startHistoryId,
                            initialPageToken: continuationState.pageToken,
                            isProcessingTask: isProcessingTask,
                            accountEmail: currentAccountEmail
                        )

                    case .partial:
                        guard let query = continuationState.query, let maxResults = continuationState.maxResults else {
                            stateManager.clearContinuationState()
                            Log.warning("Cleared invalid background partial continuation state", category: .background)
                            break
                        }

                        return await performPartialSync(
                            query: query,
                            initialPageToken: continuationState.pageToken,
                            maxResults: maxResults,
                            isProcessingTask: isProcessingTask,
                            accountEmail: currentAccountEmail
                        )
                    }
                }
            }

            if let historyId = historyId {
                return await performHistorySync(
                    startHistoryId: historyId,
                    isProcessingTask: isProcessingTask,
                    accountEmail: currentAccountEmail
                )
            } else {
                return await performPartialSync(
                    isProcessingTask: isProcessingTask,
                    accountEmail: currentAccountEmail
                )
            }
        } catch {
            Log.error("Background sync error", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    private func performHistorySync(
        startHistoryId: String,
        initialPageToken: String? = nil,
        isProcessingTask: Bool,
        accountEmail: String?
    ) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            var allHistories: [HistoryRecord] = []
            var pageToken: String? = initialPageToken
            let maxPages = isProcessingTask ? 10 : 3
            var pageCount = 0
            var latestHistoryId: String? = nil

            repeat {
                let historyResponse = try await apiClient.listHistory(startHistoryId: startHistoryId, pageToken: pageToken)

                if let histories = historyResponse.history {
                    allHistories.append(contentsOf: histories)
                } else if historyResponse.history == nil && pageCount == 0 {
                    Log.debug("No history changes since last sync", category: .background)
                }

                pageToken = historyResponse.nextPageToken
                pageCount += 1

                if let newHistoryId = historyResponse.historyId {
                    latestHistoryId = newHistoryId
                }
            } while pageToken != nil && pageCount < maxPages

            let didTruncateHistoryPagination = pageToken != nil

            let processingResult: BackgroundMessageProcessingResult
            if !allHistories.isEmpty {
                processingResult = await messageProcessor.processHistoryChanges(histories: allHistories)
            } else {
                processingResult = .empty
            }

            let continuationState: BackgroundSyncContinuationState? = {
                guard didTruncateHistoryPagination,
                      !processingResult.hadFetchFailures,
                      let pageToken else { return nil }
                return .history(
                    startHistoryId: startHistoryId,
                    pageToken: pageToken,
                    accountEmail: accountEmail
                )
            }()
            let disposition = Self.completionDisposition(
                catchUpState: continuationState,
                hadFetchFailures: processingResult.hadFetchFailures,
                latestHistoryId: latestHistoryId
            )

            if continuationState != nil, didTruncateHistoryPagination {
                Log.warning(
                    "Background history sync reached page limit (\(maxPages)); stored continuation page token for catch-up retry",
                    category: .background
                )
            } else if didTruncateHistoryPagination {
                Log.warning(
                    "Background history sync reached page limit (\(maxPages)) but had fetch failures; retrying before advancing continuation",
                    category: .background
                )
            }

            if processingResult.hadFetchFailures {
                Log.warning(
                    "Background history sync had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
            }

            return await finalizeBackgroundSync(disposition)

        } catch {
            return await handleHistorySyncError(
                error,
                startHistoryId: startHistoryId,
                initialPageToken: initialPageToken,
                isProcessingTask: isProcessingTask,
                accountEmail: accountEmail
            )
        }
    }

    private func handleHistorySyncError(
        _ error: Error,
        startHistoryId: String,
        initialPageToken: String?,
        isProcessingTask: Bool,
        accountEmail: String?
    ) async -> Bool {
        let action = errorHandler.handleError(error)

        switch action {
        case .retry:
            handleSyncError()
            return false

        case .partialSync:
            stateManager.clearContinuationState()
            return await performPartialSync(
                isProcessingTask: isProcessingTask,
                accountEmail: accountEmail
            )

        case .tokenRefreshAndRetry:
            do {
                let authSession = await MainActor.run { authSessionProvider() }
                _ = try await authSession.withFreshToken()
                return await performHistorySync(
                    startHistoryId: startHistoryId,
                    initialPageToken: initialPageToken,
                    isProcessingTask: isProcessingTask,
                    accountEmail: accountEmail
                )
            } catch {
                Log.error("Token refresh failed", category: .background, error: error)
                handleSyncError()
                return false
            }

        case .abort:
            handleSyncError()
            return false

        case .abortNoRetry:
            return false
        }
    }

    private func performPartialSync(
        query: String? = nil,
        initialPageToken: String? = nil,
        maxResults: Int? = nil,
        isProcessingTask: Bool,
        accountEmail: String?
    ) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            let maxResults = maxResults ?? (isProcessingTask ? 100 : 50)
            let maxPages = isProcessingTask ? 10 : 3

            let query = query ?? buildPartialSyncQuery()

            var allMessageIds: Set<String> = []
            var pageToken: String? = initialPageToken
            var pageCount = 0

            repeat {
                let response = try await apiClient.listMessages(
                    pageToken: pageToken,
                    maxResults: maxResults,
                    query: query
                )
                if let messages = response.messages {
                    allMessageIds.formUnion(messages.map { $0.id })
                }
                pageToken = response.nextPageToken
                pageCount += 1
            } while pageToken != nil && pageCount < maxPages

            let processingResult: BackgroundMessageProcessingResult
            if !allMessageIds.isEmpty {
                processingResult = await messageProcessor.fetchAndStoreMessages(messageIds: Array(allMessageIds))
            } else {
                processingResult = .empty
            }

            let didTruncateMessagePagination = pageToken != nil
            let continuationState: BackgroundSyncContinuationState? = {
                guard didTruncateMessagePagination,
                      !processingResult.hadFetchFailures,
                      let pageToken else { return nil }
                return .partial(
                    query: query,
                    pageToken: pageToken,
                    maxResults: maxResults,
                    accountEmail: accountEmail
                )
            }()
            let profile = continuationState != nil || processingResult.hadFetchFailures
                ? nil
                : try await apiClient.getProfile()
            let disposition = Self.completionDisposition(
                catchUpState: continuationState,
                hadFetchFailures: processingResult.hadFetchFailures,
                latestHistoryId: profile?.historyId
            )

            if continuationState != nil, didTruncateMessagePagination {
                Log.warning(
                    "Background partial sync reached page limit (\(maxPages)); stored continuation page token for catch-up retry",
                    category: .background
                )
            } else if didTruncateMessagePagination {
                Log.warning(
                    "Background partial sync reached page limit (\(maxPages)) but had fetch failures; retrying before advancing continuation",
                    category: .background
                )
            }

            if processingResult.hadFetchFailures {
                Log.warning(
                    "Background partial sync had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
            }

            return await finalizeBackgroundSync(
                disposition,
                accountEmail: profile?.emailAddress ?? accountEmail
            )
        } catch {
            Log.error("Partial sync error", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    private func buildPartialSyncQuery() -> String {
        let installTimestamp = UserDefaults.standard.double(forKey: "installTimestamp")

        if installTimestamp > 0 {
            let cutoffTimestamp = Int(installTimestamp) - 300 // 5 min buffer
            return "after:\(cutoffTimestamp) -label:spam -label:drafts -label:trash"
        }

        let oneDayAgo = Int(Date().timeIntervalSince1970) - (24 * 60 * 60)
        return "after:\(oneDayAgo) -label:spam -label:drafts -label:trash"
    }

    // MARK: - Error Handling

    private func handleSyncError() {
        if let backoff = stateManager.incrementRetryAndGetBackoff() {
            taskScheduler.scheduleRetryAfterBackoff(backoff)
        }
    }

    private func scheduleCatchUpRetry() {
        // Catch-up is progress, not failure, so bypass the exponential-backoff
        // retry counter and reschedule on a short fixed delay instead.
        taskScheduler.scheduleRetryAfterBackoff(Self.catchUpRetryDelay)
    }

    private func finalizeBackgroundSync(
        _ disposition: BackgroundSyncCompletionDisposition,
        accountEmail: String? = nil
    ) async -> Bool {
        switch disposition.retryAction {
        case .none:
            do {
                if let historyId = disposition.historyIdToStore {
                    try await stateManager.storeHistoryId(historyId, accountEmail: accountEmail)
                }
                stateManager.clearContinuationState()
            } catch {
                Log.error("Failed to store background sync state", category: .background, error: error)
                handleSyncError()
                return false
            }

            if disposition.shouldResetRetryState {
                stateManager.resetRetryCount()
            }
            return true

        case .failureBackoff:
            handleSyncError()
            return false

        case .catchUp:
            do {
                guard let continuationState = disposition.continuationState else {
                    Log.warning("Background catch-up retry requested without continuation state", category: .background)
                    handleSyncError()
                    return false
                }

                try stateManager.storeContinuationState(continuationState)
            } catch {
                Log.error("Failed to store background sync continuation state", category: .background, error: error)
                handleSyncError()
                return false
            }

            scheduleCatchUpRetry()
            return false
        }
    }

    static func completionDisposition(
        catchUpState: BackgroundSyncContinuationState? = nil,
        hadFetchFailures: Bool,
        latestHistoryId: String?
    ) -> BackgroundSyncCompletionDisposition {
        if hadFetchFailures {
            return BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: nil,
                retryAction: .failureBackoff,
                shouldResetRetryState: false
            )
        }

        if let catchUpState {
            return BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: catchUpState,
                retryAction: .catchUp,
                shouldResetRetryState: false
            )
        }

        return BackgroundSyncCompletionDisposition(
            historyIdToStore: latestHistoryId,
            continuationState: nil,
            retryAction: .none,
            shouldResetRetryState: true
        )
    }
}
