import Foundation
import BackgroundTasks
import CoreData

/// Main orchestrator for background sync operations
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    // MARK: - Components

    private let taskScheduler = BackgroundTaskScheduler.shared
    private let stateManager: BackgroundSyncStateManager
    private let errorHandler = BackgroundSyncErrorHandler()
    private let messageProcessor: BackgroundMessageProcessor

    private let syncQueue = DispatchQueue(label: "com.esc.inboxchat.backgroundsync", qos: .background)

    @MainActor private lazy var apiClient = GmailAPIClient.shared
    @MainActor private lazy var syncEngine = SyncEngine.shared

    private init() {
        let coreDataStack = CoreDataStack.shared
        self.stateManager = BackgroundSyncStateManager(coreDataStack: coreDataStack)
        self.messageProcessor = BackgroundMessageProcessor(coreDataStack: coreDataStack)

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

        let backgroundTask = Task { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            let success = await self.performDeltaSync(isProcessingTask: false)
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            backgroundTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func handleProcessing(task: BGProcessingTask) {
        taskScheduler.scheduleProcessingTask()

        let backgroundTask = Task { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            let success = await self.performDeltaSync(isProcessingTask: true)
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            backgroundTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Sync Orchestration

    private func performDeltaSync(isProcessingTask: Bool) async -> Bool {
        do {
            _ = try await AuthSession.shared.withFreshToken()

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

            if !allHistories.isEmpty {
                await messageProcessor.processHistoryChanges(histories: allHistories)
            }

            if let latestHistoryId = latestHistoryId {
                stateManager.storeHistoryId(latestHistoryId)
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
                _ = try await AuthSession.shared.withFreshToken()
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

            if !allHistories.isEmpty {
                await messageProcessor.processHistoryChanges(histories: allHistories)
            }

            if let latestHistoryId = latestHistoryId {
                stateManager.storeHistoryId(latestHistoryId)
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
            let maxResults = isProcessingTask ? 100 : 50

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

            let response = try await apiClient.listMessages(maxResults: maxResults, query: query)

            if let messages = response.messages {
                await messageProcessor.fetchAndStoreMessages(messageIds: messages.map { $0.id })
            }

            let profile = try await apiClient.getProfile()
            stateManager.storeHistoryId(profile.historyId)

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
