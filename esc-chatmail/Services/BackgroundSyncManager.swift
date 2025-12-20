import Foundation
import BackgroundTasks
import CoreData

class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    
    private let refreshTaskIdentifier = "com.esc.inboxchat.refresh"
    private let processingTaskIdentifier = "com.esc.inboxchat.processing"
    
    private let syncQueue = DispatchQueue(label: "com.esc.inboxchat.backgroundsync", qos: .background)
    private let maxRetries = 3
    private let initialBackoffSeconds: TimeInterval = 30
    private let maxBackoffSeconds: TimeInterval = 3600
    
    private var currentRetryCount = 0
    private var currentBackoff: TimeInterval = 30
    
    @MainActor private lazy var apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    @MainActor private lazy var syncEngine = SyncEngine.shared
    
    private init() {}
    
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleAppRefresh(task: task)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            self?.handleProcessing(task: task)
        }
    }
    
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background refresh scheduled")
        } catch {
            print("Failed to schedule background refresh: \(error)")
        }
    }
    
    func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background processing scheduled")
        } catch {
            print("Failed to schedule background processing: \(error)")
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()

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
        scheduleProcessingTask()

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
    
    private func performDeltaSync(isProcessingTask: Bool) async -> Bool {
        do {
            _ = try await AuthSession.shared.withFreshToken()
            
            let historyId = getStoredHistoryId()
            
            if let historyId = historyId {
                return await performHistorySync(startHistoryId: historyId, isProcessingTask: isProcessingTask)
            } else {
                return await performPartialSync(isProcessingTask: isProcessingTask)
            }
        } catch {
            print("Background sync error: \(error)")
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
                    // No history changes - this is normal, just update the history ID
                    print("No history changes since last sync")
                }

                pageToken = historyResponse.nextPageToken
                pageCount += 1

                if let newHistoryId = historyResponse.historyId {
                    latestHistoryId = newHistoryId
                }
            } while pageToken != nil && pageCount < maxPages

            if !allHistories.isEmpty {
                await processHistoryChanges(histories: allHistories)
            }

            // Only update history ID after successful processing
            if let latestHistoryId = latestHistoryId {
                storeHistoryId(latestHistoryId)
            }

            resetRetryCount()
            return true

        } catch {
            return await handleHistorySyncError(error, isProcessingTask: isProcessingTask)
        }
    }

    /// Handles errors from history sync with appropriate recovery strategies
    private func handleHistorySyncError(_ error: Error, isProcessingTask: Bool) async -> Bool {
        // Check for API errors first
        if let apiError = error as? APIError {
            switch apiError {
            case .historyIdExpired:
                print("History ID expired (APIError), falling back to partial sync")
                return await performPartialSync(isProcessingTask: isProcessingTask)

            case .authenticationError:
                print("Authentication error during background sync, attempting token refresh")
                // Try to refresh token and retry once
                do {
                    _ = try await AuthSession.shared.withFreshToken()
                    // Token refreshed, retry the sync
                    if let historyId = getStoredHistoryId() {
                        return await performHistorySyncRetry(startHistoryId: historyId, isProcessingTask: isProcessingTask)
                    }
                } catch {
                    print("Token refresh failed: \(error)")
                }
                handleSyncError()
                return false

            case .rateLimited:
                print("Rate limited during background sync, will retry with backoff")
                handleSyncError() // Uses exponential backoff
                return false

            case .timeout, .networkError:
                print("Network issue during background sync: \(apiError)")
                handleSyncError()
                return false

            case .serverError(let code):
                print("Server error \(code) during background sync")
                if code >= 500 {
                    // Server errors are retriable
                    handleSyncError()
                }
                return false

            default:
                print("API error during background sync: \(apiError)")
                handleSyncError()
                return false
            }
        }

        // Check for NSError (including 404 history expired)
        if let nsError = error as NSError? {
            if nsError.code == 404 || (nsError.domain.contains("Gmail") && nsError.code == 404) {
                print("History too old (404), falling back to partial sync")
                return await performPartialSync(isProcessingTask: isProcessingTask)
            }

            if nsError.code == 401 {
                print("401 Unauthorized, attempting token refresh")
                do {
                    _ = try await AuthSession.shared.withFreshToken()
                    if let historyId = getStoredHistoryId() {
                        return await performHistorySyncRetry(startHistoryId: historyId, isProcessingTask: isProcessingTask)
                    }
                } catch {
                    print("Token refresh failed: \(error)")
                }
                handleSyncError()
                return false
            }

            if nsError.code == 429 {
                print("Rate limited (429), will retry with backoff")
                handleSyncError()
                return false
            }
        }

        // Check for URLError
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                print("Network unavailable during background sync")
                // Don't increment retry count for network unavailable
                return false
            case .timedOut:
                print("Request timed out during background sync")
                handleSyncError()
                return false
            default:
                print("URL error during background sync: \(urlError)")
                handleSyncError()
                return false
            }
        }

        print("Unknown error during history sync: \(error)")
        handleSyncError()
        return false
    }

    /// Single retry attempt after token refresh
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
                await processHistoryChanges(histories: allHistories)
            }

            if let latestHistoryId = latestHistoryId {
                storeHistoryId(latestHistoryId)
            }

            resetRetryCount()
            return true

        } catch {
            print("History sync retry failed: \(error)")
            handleSyncError()
            return false
        }
    }
    
    private func performPartialSync(isProcessingTask: Bool) async -> Bool {
        do {
            let maxResults = isProcessingTask ? 100 : 50
            // Exclude spam and draft messages from the query
            let response = try await apiClient.listMessages(maxResults: maxResults, query: "-label:spam -label:drafts")

            if let messages = response.messages {
                await fetchAndStoreMessages(messageIds: messages.map { $0.id })
            }
            
            let profile = try await apiClient.getProfile()
            storeHistoryId(profile.historyId)
            
            resetRetryCount()
            return true
        } catch {
            print("Partial sync error: \(error)")
            handleSyncError()
            return false
        }
    }
    
    private func processHistoryChanges(histories: [HistoryRecord]) async {
        let context = coreDataStack.newBackgroundContext()
        
        var messagesToFetch: Set<String> = []
        var messagesToDelete: Set<String> = []
        var messageLabelsToUpdate: [String: [String]] = [:]
        
        for history in histories {
            if let messagesAdded = history.messagesAdded {
                for messageAdded in messagesAdded {
                    // Skip spam messages
                    if let labelIds = messageAdded.message.labelIds, labelIds.contains("SPAM") {
                        print("Skipping spam message from history: \(messageAdded.message.id)")
                        continue
                    }
                    messagesToFetch.insert(messageAdded.message.id)
                }
            }
            
            if let messagesDeleted = history.messagesDeleted {
                for messageDeleted in messagesDeleted {
                    messagesToDelete.insert(messageDeleted.message.id)
                }
            }
            
            if let labelsAdded = history.labelsAdded {
                for labelAdded in labelsAdded {
                    let messageId = labelAdded.message.id
                    var labels = messageLabelsToUpdate[messageId] ?? []
                    labels.append(contentsOf: labelAdded.labelIds)
                    messageLabelsToUpdate[messageId] = labels
                }
            }
            
            if let labelsRemoved = history.labelsRemoved {
                for labelRemoved in labelsRemoved {
                    messagesToFetch.insert(labelRemoved.message.id)
                }
            }
        }
        
        await deleteMessages(messageIds: Array(messagesToDelete), in: context)
        
        if !messagesToFetch.isEmpty {
            await fetchAndStoreMessages(messageIds: Array(messagesToFetch))
        }
        
        coreDataStack.saveIfNeeded(context: context)
    }
    
    private func fetchAndStoreMessages(messageIds: [String]) async {
        let context = coreDataStack.newBackgroundContext()

        // Prefetch labels for efficient lookups
        let labelCache = await syncEngine.prefetchLabelsForBackground(in: context)

        let batchSize = 10
        var successCount = 0
        var failedCount = 0

        for batch in messageIds.chunked(into: batchSize) {
            await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
                for messageId in batch {
                    group.addTask { [weak self] in
                        guard let self = self else {
                            return (messageId, .failure(NSError(domain: "BackgroundSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"])))
                        }
                        do {
                            let message = try await self.apiClient.getMessage(id: messageId)
                            return (messageId, .success(message))
                        } catch {
                            return (messageId, .failure(error))
                        }
                    }
                }

                for await (messageId, result) in group {
                    switch result {
                    case .success(let message):
                        await syncEngine.saveMessage(message, labelCache: labelCache, in: context)
                        successCount += 1
                    case .failure(let error):
                        failedCount += 1
                        print("Failed to fetch message \(messageId) in background: \(error.localizedDescription)")
                    }
                }
            }
        }

        if failedCount > 0 {
            print("Background sync: fetched \(successCount) messages, \(failedCount) failed")
        }

        await syncEngine.updateConversationRollups(in: context)

        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            print("Failed to save background sync context: \(error.localizedDescription)")
        }
    }
    
    private func deleteMessages(messageIds: [String], in context: NSManagedObjectContext) async {
        await context.perform {
            for messageId in messageIds {
                let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)

                do {
                    let messages = try context.fetch(fetchRequest)
                    for message in messages {
                        context.delete(message)
                    }
                } catch {
                    print("Failed to delete message \(messageId): \(error)")
                }
            }
        }
    }
    
    private func getStoredHistoryId() -> String? {
        var historyId: String? = nil
        let context = coreDataStack.newBackgroundContext()
        context.performAndWait {
            let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
            fetchRequest.fetchLimit = 1

            do {
                let accounts = try context.fetch(fetchRequest)
                historyId = accounts.first?.historyId
            } catch {
                print("Failed to fetch historyId: \(error)")
            }
        }
        return historyId
    }
    
    private func storeHistoryId(_ historyId: String) {
        Task {
            do {
                try await coreDataStack.performBackgroundTask { [weak self] context in
                    guard let self = self else { return }
                    let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
                    fetchRequest.fetchLimit = 1

                    let accounts = try context.fetch(fetchRequest)
                    if let account = accounts.first {
                        account.historyId = historyId
                        try self.coreDataStack.save(context: context)
                    }
                }
            } catch {
                print("Failed to store historyId: \(error)")
            }
        }
    }
    
    private func handleSyncError() {
        currentRetryCount += 1
        
        if currentRetryCount >= maxRetries {
            currentRetryCount = 0
            currentBackoff = initialBackoffSeconds
        } else {
            currentBackoff = min(currentBackoff * 2, maxBackoffSeconds)
            scheduleRetryAfterBackoff()
        }
    }
    
    private func scheduleRetryAfterBackoff() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: currentBackoff)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Retry scheduled after \(currentBackoff) seconds")
        } catch {
            print("Failed to schedule retry: \(error)")
        }
    }
    
    private func resetRetryCount() {
        currentRetryCount = 0
        currentBackoff = initialBackoffSeconds
    }
}