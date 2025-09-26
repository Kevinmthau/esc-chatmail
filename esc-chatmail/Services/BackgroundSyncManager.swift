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
            
            repeat {
                let historyResponse = try await apiClient.listHistory(startHistoryId: startHistoryId, pageToken: pageToken)
                
                if let histories = historyResponse.history {
                    allHistories.append(contentsOf: histories)
                }
                
                pageToken = historyResponse.nextPageToken
                pageCount += 1
                
                if let newHistoryId = historyResponse.historyId {
                    storeHistoryId(newHistoryId)
                }
            } while pageToken != nil && pageCount < maxPages
            
            if !allHistories.isEmpty {
                await processHistoryChanges(histories: allHistories)
            }
            
            resetRetryCount()
            return true
            
        } catch {
            if let nsError = error as NSError? {
                if nsError.code == 404 || (nsError.domain.contains("Gmail") && nsError.code == 404) {
                    print("History too old, falling back to partial sync")
                    return await performPartialSync(isProcessingTask: isProcessingTask)
                }
            }
            
            print("History sync error: \(error)")
            handleSyncError()
            return false
        }
    }
    
    private func performPartialSync(isProcessingTask: Bool) async -> Bool {
        do {
            let maxResults = isProcessingTask ? 100 : 50
            // Exclude spam messages from the query
            let response = try await apiClient.listMessages(maxResults: maxResults, query: "-label:spam")

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
        let batchSize = 10

        for batch in messageIds.chunked(into: batchSize) {
            await withTaskGroup(of: GmailMessage?.self) { group in
                for messageId in batch {
                    group.addTask { [weak self] in
                        try? await self?.apiClient.getMessage(id: messageId)
                    }
                }

                for await message in group {
                    if let message = message {
                        await syncEngine.saveMessage(message, in: context)
                    }
                }
            }
        }

        await syncEngine.updateConversationRollups(in: context)
        coreDataStack.saveIfNeeded(context: context)
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