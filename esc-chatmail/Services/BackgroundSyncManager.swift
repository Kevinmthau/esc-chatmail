import Foundation
import BackgroundTasks
import CoreData
import os

/// Main orchestrator for background sync operations
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

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

            let historyId = await stateManager.getStoredHistoryId()

            if let historyId = historyId {
                return await performHistorySync(startHistoryId: historyId, isProcessingTask: isProcessingTask)
            } else {
                return await performPartialSync(isProcessingTask: isProcessingTask)
            }
        } catch {
            Log.error("Background sync error", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    private func performHistorySync(startHistoryId: String, isProcessingTask: Bool) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            var allHistories: [HistoryRecord] = []
            var pageToken: String? = nil
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

            if didTruncateHistoryPagination {
                Log.warning(
                    "Background history sync reached page limit (\(maxPages)); keeping stored historyId to avoid data loss",
                    category: .background
                )
            } else if processingResult.hadFetchFailures {
                Log.warning(
                    "Background history sync had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
                handleSyncError()
                return false
            } else if let latestHistoryId = latestHistoryId {
                try await stateManager.storeHistoryId(latestHistoryId)
            }

            stateManager.resetRetryCount()
            return true

        } catch {
            return await handleHistorySyncError(error, startHistoryId: startHistoryId, isProcessingTask: isProcessingTask)
        }
    }

    private func handleHistorySyncError(_ error: Error, startHistoryId: String, isProcessingTask: Bool) async -> Bool {
        let action = errorHandler.handleError(error)

        switch action {
        case .retry:
            handleSyncError()
            return false

        case .partialSync:
            return await performPartialSync(isProcessingTask: isProcessingTask)

        case .tokenRefreshAndRetry:
            do {
                let authSession = await MainActor.run { authSessionProvider() }
                _ = try await authSession.withFreshToken()
                return await performHistorySyncRetry(startHistoryId: startHistoryId, isProcessingTask: isProcessingTask)
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

    private func performHistorySyncRetry(startHistoryId: String, isProcessingTask: Bool) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            var allHistories: [HistoryRecord] = []
            var pageToken: String? = nil
            let maxPages = isProcessingTask ? 10 : 3
            var pageCount = 0
            var latestHistoryId: String? = nil

            repeat {
                let historyResponse = try await apiClient.listHistory(startHistoryId: startHistoryId, pageToken: pageToken)

                if let histories = historyResponse.history {
                    allHistories.append(contentsOf: histories)
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

            if didTruncateHistoryPagination {
                Log.warning(
                    "Background history retry reached page limit (\(maxPages)); keeping stored historyId to avoid data loss",
                    category: .background
                )
            } else if processingResult.hadFetchFailures {
                Log.warning(
                    "Background history retry had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
                handleSyncError()
                return false
            } else if let latestHistoryId = latestHistoryId {
                try await stateManager.storeHistoryId(latestHistoryId)
            }

            stateManager.resetRetryCount()
            return true

        } catch {
            Log.error("History sync retry failed", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    private func performPartialSync(isProcessingTask: Bool) async -> Bool {
        do {
            let apiClient = await MainActor.run { apiClientProvider() }
            let maxResults = isProcessingTask ? 100 : 50
            let maxPages = isProcessingTask ? 10 : 3

            // Use install timestamp to only fetch messages from install time forward
            let installTimestamp = UserDefaults.standard.double(forKey: "installTimestamp")
            let query: String
            if installTimestamp > 0 {
                let cutoffTimestamp = Int(installTimestamp) - 300 // 5 min buffer
                query = "after:\(cutoffTimestamp) -label:spam -label:drafts"
            } else {
                // Fallback: only fetch messages from last 24 hours
                let oneDayAgo = Int(Date().timeIntervalSince1970) - (24 * 60 * 60)
                query = "after:\(oneDayAgo) -label:spam -label:drafts"
            }

            var allMessageIds: Set<String> = []
            var pageToken: String? = nil
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
            if didTruncateMessagePagination {
                Log.warning(
                    "Background partial sync reached page limit (\(maxPages)); skipping historyId advance to avoid missing messages",
                    category: .background
                )
            } else if processingResult.hadFetchFailures {
                Log.warning(
                    "Background partial sync had \(processingResult.failedFetchCount) message fetch failures; keeping stored historyId and scheduling retry",
                    category: .background
                )
                handleSyncError()
                return false
            } else {
                let profile = try await apiClient.getProfile()
                try await stateManager.storeHistoryId(
                    profile.historyId,
                    accountEmail: profile.emailAddress
                )
            }

            stateManager.resetRetryCount()
            return true
        } catch {
            Log.error("Partial sync error", category: .background, error: error)
            handleSyncError()
            return false
        }
    }

    // MARK: - Error Handling

    private func handleSyncError() {
        if let backoff = stateManager.incrementRetryAndGetBackoff() {
            taskScheduler.scheduleRetryAfterBackoff(backoff)
        }
    }
}
