import Foundation
import CoreData
import Combine
import Network

extension Notification.Name {
    static let syncCompleted = Notification.Name("com.esc.inboxchat.syncCompleted")
}

// MARK: - Network Reachable Actor
private actor NetworkReachableActor {
    private var _isReachable = true

    func setReachable(_ reachable: Bool) {
        _isReachable = reachable
    }

    func isReachable() -> Bool {
        return _isReachable
    }
}

@MainActor
final class SyncEngine: ObservableObject, @unchecked Sendable {
    static let shared = SyncEngine()
    
    @Published var isSyncing = false
    @Published var syncProgress: Double = 0.0
    @Published var syncStatus: String = ""
    
    private let apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    private let messageProcessor = MessageProcessor()
    private let htmlContentHandler = HTMLContentHandler()
    private let conversationManager = ConversationManager()
    private let attachmentDownloader = AttachmentDownloader.shared
    private var myAliases: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private let networkReachableActor = NetworkReachableActor()
    
    private init() {
        setupNetworkMonitoring()
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task {
                await self?.networkReachableActor.setReachable(path.status == .satisfied)
            }
            if !path.isExpensive && path.status == .satisfied {
                print("Network is reachable")
            } else {
                print("Network status: \(path.status), expensive: \(path.isExpensive)")
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }
    
    private nonisolated func isNetworkAvailable() async -> Bool {
        return await networkReachableActor.isReachable()
    }
    
    func performInitialSync() async throws {
        await MainActor.run {
            self.isSyncing = true
            self.syncProgress = 0.0
            self.syncStatus = "Starting sync..."
        }

        let context = coreDataStack.newBackgroundContext()
        await removeDuplicateMessages(in: context)
        await removeDuplicateConversations(in: context)

        do {
            let profile = try await apiClient.getProfile()

            // Fetch user aliases from Gmail settings
            let sendAsList = try await apiClient.listSendAs()
            let aliases = sendAsList
                .filter { $0.treatAsAlias == true || $0.isPrimary == true }
                .map { $0.sendAsEmail }

            // Build myAliases set with normalized emails
            myAliases = Set(([profile.emailAddress] + aliases).map(normalizedEmail))

            _ = await saveAccount(profile: profile, aliases: aliases, in: context)

            await MainActor.run {
                self.syncStatus = "Fetching labels..."
                self.syncProgress = 0.1
            }

            let labels = try await apiClient.listLabels()
            await saveLabels(labels, in: context)

            await MainActor.run {
                self.syncStatus = "Fetching messages..."
                self.syncProgress = 0.2
            }

            // Get installation timestamp to filter messages
            let installationTimestamp = KeychainService.shared.getOrCreateInstallationTimestamp()

            // Convert timestamp to Gmail query format (epoch seconds)
            let epochSeconds = Int(installationTimestamp.timeIntervalSince1970)
            // Exclude spam messages from the query
            let gmailQuery = "after:\(epochSeconds) -label:spam"

            print("Syncing only non-spam messages after installation: \(installationTimestamp)")

            var allMessageIds: [String] = []
            var pageToken: String? = nil

            repeat {
                let response = try await apiClient.listMessages(pageToken: pageToken, maxResults: 500, query: gmailQuery)
                if let messages = response.messages {
                    allMessageIds.append(contentsOf: messages.map { $0.id })
                }
                pageToken = response.nextPageToken

                let currentCount = allMessageIds.count
                await MainActor.run {
                    self.syncProgress = min(0.4, 0.2 + (Double(currentCount) / 10000.0) * 0.2)
                }
            } while pageToken != nil
            
            let totalMessages = allMessageIds.count
            await MainActor.run {
                self.syncStatus = "Processing \(totalMessages) messages..."
                self.syncProgress = 0.4
            }
            
            let batchSize = 50
            let totalBatches = max(1, (totalMessages + batchSize - 1) / batchSize)  // Prevent division by zero
            for (index, batch) in allMessageIds.chunked(into: batchSize).enumerated() {
                await processBatchOfMessages(batch, in: context)
                
                let progress = 0.4 + (Double(index) / Double(totalBatches)) * 0.5
                let processedCount = min((index + 1) * batchSize, totalMessages)
                await MainActor.run {
                    self.syncProgress = min(0.9, progress)
                    self.syncStatus = "Processing messages... \(processedCount)/\(totalMessages)"
                }
            }
            
            await updateConversationRollups(in: context)
            
            // Save the background context first
            do {
                try coreDataStack.save(context: context)
            } catch {
                print("Failed to save sync data: \(error)")
                throw error // Propagate sync errors
            }
            
            // Update account's historyId in the main context
            await updateAccountHistoryId(profile.historyId)
            
            // Start downloading attachments in the background
            Task {
                await attachmentDownloader.enqueueAllPendingAttachments()
            }
            
            await MainActor.run {
                self.syncProgress = 1.0
                self.syncStatus = "Sync complete"
                self.isSyncing = false
            }
            
        } catch {
            await MainActor.run {
                self.syncStatus = "Sync failed: \(error.localizedDescription)"
                self.isSyncing = false
            }
            throw error
        }
    }
    
    func performIncrementalSync() async throws {
        // Check network connectivity first
        guard await isNetworkAvailable() else {
            print("Network not available, skipping sync")
            await MainActor.run {
                self.syncStatus = "Network unavailable"
                self.isSyncing = false
            }
            return
        }
        
        guard let account = try await fetchAccount() else { 
            print("No account found for incremental sync")
            return 
        }
        
        // Extract account properties while still on the main thread
        let historyId = account.historyId
        let email = account.email
        let aliases = account.aliasesArray
        
        print("Starting incremental sync with historyId: \(historyId ?? "nil")")
        
        guard let historyId = historyId else {
            print("No historyId found, falling back to initial sync")
            try await performInitialSync()
            return
        }
        
        // Initialize myAliases with stored aliases
        myAliases = Set(([email] + aliases).map(normalizedEmail))
        
        await MainActor.run {
            self.isSyncing = true
            self.syncStatus = "Checking for updates..."
        }
        
        let context = coreDataStack.newBackgroundContext()
        
        do {
            var pageToken: String? = nil
            var latestHistoryId = historyId
            
            repeat {
                let response = try await apiClient.listHistory(startHistoryId: historyId, pageToken: pageToken)
                
                if let history = response.history {
                    print("Received \(history.count) history records")
                    for record in history {
                        await processHistoryRecord(record, in: context)
                    }
                } else {
                    print("No history records in response")
                }
                
                if let newHistoryId = response.historyId {
                    print("Updating historyId from \(latestHistoryId) to \(newHistoryId)")
                    latestHistoryId = newHistoryId
                }
                
                pageToken = response.nextPageToken
            } while pageToken != nil
            
            await updateConversationRollups(in: context)
            await removeDuplicateConversations(in: context)
            
            // Update account's historyId in the proper context
            await updateAccountHistoryId(latestHistoryId)

            do {
                try coreDataStack.save(context: context)
            } catch {
                print("Failed to save incremental sync: \(error)")
                throw error // Propagate sync errors
            }
            
            // Force refresh the view context to ensure UI updates
            await MainActor.run {
                self.coreDataStack.viewContext.refreshAllObjects()
                self.syncStatus = "Sync complete"
                self.isSyncing = false
                
                // Post notification to update UI
                NotificationCenter.default.post(name: .syncCompleted, object: nil)
            }
            
        } catch {
            if error.localizedDescription.contains("too old") {
                try await performInitialSync()
            } else {
                await MainActor.run {
                    self.syncStatus = "Sync failed: \(error.localizedDescription)"
                    self.isSyncing = false
                }
                throw error
            }
        }
    }
    
    private func processBatchOfMessages(_ ids: [String], in context: NSManagedObjectContext) async {
        await withTaskGroup(of: GmailMessage?.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    try? await self?.apiClient.getMessage(id: id)
                }
            }
            
            for await message in group {
                if let message = message {
                    await saveMessage(message, in: context)
                }
            }
        }
    }
    
    func saveMessage(_ gmailMessage: GmailMessage, in context: NSManagedObjectContext) async {
        // Skip messages in SPAM folder
        if let labelIds = gmailMessage.labelIds, labelIds.contains("SPAM") {
            print("Skipping spam message: \(gmailMessage.id)")
            return
        }

        // Process the Gmail message
        guard let processedMessage = messageProcessor.processGmailMessage(gmailMessage, myAliases: myAliases, in: context) else {
            return
        }

        // Check if message is from before installation
        let installationTimestamp = KeychainService.shared.getOrCreateInstallationTimestamp()
        if processedMessage.internalDate < installationTimestamp {
            print("Skipping message from before installation: \(processedMessage.id) (\(processedMessage.internalDate) < \(installationTimestamp))")
            return
        }

        // Check for existing message and update if needed
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        if let existingMessage = try? context.fetch(request).first {
            // Update existing message properties that might have changed
            existingMessage.isUnread = processedMessage.isUnread
            existingMessage.snippet = processedMessage.snippet
            existingMessage.cleanedSnippet = processedMessage.cleanedSnippet

            // Update labels
            existingMessage.labels = nil
            for labelId in processedMessage.labelIds {
                if let label = await findLabel(id: labelId, in: context) {
                    existingMessage.addToLabels(label)
                }
            }

            print("Updated existing message: \(processedMessage.id)")
            return
        }
        
        // Create conversation identity and find/create conversation
        let identity = conversationManager.createConversationIdentity(from: processedMessage.headers, myAliases: myAliases)
        let conversation = await conversationManager.findOrCreateConversation(for: identity, in: context)
        
        // Create Core Data message entity
        let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context) as! Message
        message.id = processedMessage.id
        message.gmThreadId = processedMessage.gmThreadId
        message.snippet = processedMessage.snippet
        message.cleanedSnippet = processedMessage.cleanedSnippet
        message.conversation = conversation
        message.internalDate = processedMessage.internalDate
        message.subject = processedMessage.headers.subject
        message.isFromMe = processedMessage.headers.isFromMe
        message.isUnread = processedMessage.isUnread
        message.hasAttachments = processedMessage.hasAttachments
        
        // Save participants
        if let from = processedMessage.headers.from {
            await saveParticipant(from: from, kind: .from, for: message, in: context)
        }
        for recipient in processedMessage.headers.to {
            await saveParticipant(from: "\(recipient.displayName ?? "") <\(recipient.email)>", kind: .to, for: message, in: context)
        }
        for recipient in processedMessage.headers.cc {
            await saveParticipant(from: "\(recipient.displayName ?? "") <\(recipient.email)>", kind: .cc, for: message, in: context)
        }
        for recipient in processedMessage.headers.bcc {
            await saveParticipant(from: "\(recipient.displayName ?? "") <\(recipient.email)>", kind: .bcc, for: message, in: context)
        }
        
        // Save labels
        for labelId in processedMessage.labelIds {
            if let label = await findLabel(id: labelId, in: context) {
                message.addToLabels(label)
            }
        }
        
        // Save HTML content if present
        if let htmlBody = processedMessage.htmlBody {
            if let fileURL = htmlContentHandler.saveHTML(htmlBody, for: processedMessage.id) {
                message.bodyStorageURI = fileURL.absoluteString
            }
        }
        
        // Save attachment info
        for attachmentInfo in processedMessage.attachmentInfo {
            let attachment = NSEntityDescription.insertNewObject(forEntityName: "Attachment", into: context) as! Attachment
            attachment.setValue(attachmentInfo.id, forKey: "id")
            attachment.setValue(attachmentInfo.filename, forKey: "filename")
            attachment.setValue(attachmentInfo.mimeType, forKey: "mimeType")
            attachment.setValue(Int64(attachmentInfo.size), forKey: "byteSize")
            attachment.setValue("queued", forKey: "stateRaw")
            attachment.setValue(message, forKey: "message")
        }
        
        // Update conversation's lastMessageDate to bump it to the top
        if conversation.lastMessageDate == nil || message.internalDate > conversation.lastMessageDate! {
            conversation.lastMessageDate = message.internalDate
            conversation.snippet = message.cleanedSnippet ?? message.snippet
        }
    }
    
    private func saveParticipant(from headerValue: String, kind: ParticipantKind, for message: Message, in context: NSManagedObjectContext) async {
        guard let email = EmailNormalizer.extractEmail(from: headerValue) else { return }
        let normalizedEmail = EmailNormalizer.normalize(email)
        let displayName = EmailNormalizer.extractDisplayName(from: headerValue)
        
        let person = conversationManager.findOrCreatePerson(email: normalizedEmail, displayName: displayName, in: context)
        
        let participant = NSEntityDescription.insertNewObject(forEntityName: "MessageParticipant", into: context) as! MessageParticipant
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }
    
    private func saveParticipants(from headerValue: String, kind: ParticipantKind, for message: Message, in context: NSManagedObjectContext) async {
        let emails = headerValue.split(separator: ",")
        for emailStr in emails {
            await saveParticipant(from: String(emailStr), kind: kind, for: message, in: context)
        }
    }
    
    
    
    private func findLabel(id: String, in context: NSManagedObjectContext) async -> Label? {
        let request = Label.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        return try? context.fetch(request).first
    }
    
    private func saveLabels(_ gmailLabels: [GmailLabel], in context: NSManagedObjectContext) async {
        for gmailLabel in gmailLabels {
            let label = NSEntityDescription.insertNewObject(forEntityName: "Label", into: context) as! Label
            label.id = gmailLabel.id
            label.name = gmailLabel.name
        }
    }
    
    private func saveAccount(profile: GmailProfile, aliases: [String], in context: NSManagedObjectContext) async -> Account {
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", profile.emailAddress)
        
        if let existing = try? context.fetch(request).first {
            existing.aliasesArray = aliases
            return existing
        }
        
        let account = NSEntityDescription.insertNewObject(forEntityName: "Account", into: context) as! Account
        account.id = profile.emailAddress
        account.email = profile.emailAddress
        account.historyId = profile.historyId
        account.aliasesArray = aliases
        return account
    }
    
    private nonisolated func fetchAccount() async throws -> Account? {
        return await withCheckedContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                let account = try? context.fetch(request).first
                continuation.resume(returning: account)
            }
        }
    }
    
    private nonisolated func updateAccountHistoryId(_ historyId: String) async {
        await withCheckedContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform { [weak self] in
                guard let self = self else { return }
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                if let account = try? context.fetch(request).first {
                    account.historyId = historyId
                    do {
                        try self.coreDataStack.save(context: context)
                    } catch {
                        print("Failed to save history ID: \(error)")
                        // Non-critical - continue
                    }
                }
                continuation.resume()
            }
        } as Void
    }
    
    nonisolated func updateConversationRollups(in context: NSManagedObjectContext) async {
        await conversationManager.updateAllConversationRollups(in: context)
    }
    
    private func processHistoryRecord(_ record: HistoryRecord, in context: NSManagedObjectContext) async {
        if let messagesAdded = record.messagesAdded {
            print("Processing \(messagesAdded.count) new messages from history")
            for added in messagesAdded {
                // Skip spam messages
                if let labelIds = added.message.labelIds, labelIds.contains("SPAM") {
                    print("Skipping spam message from history: \(added.message.id)")
                    continue
                }

                // History API returns partial messages - fetch full details
                if let fullMessage = try? await apiClient.getMessage(id: added.message.id) {
                    print("Fetched full message: \(fullMessage.id)")
                    await saveMessage(fullMessage, in: context)
                } else {
                    print("Failed to fetch full message for ID: \(added.message.id)")
                    // Fall back to partial message data
                    await saveMessage(added.message, in: context)
                }
                // The conversation lastMessageDate will be updated in saveMessage
            }
        }
        
        if let messagesDeleted = record.messagesDeleted {
            for deleted in messagesDeleted {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", deleted.message.id)
                if let message = try? context.fetch(request).first {
                    context.delete(message)
                }
            }
        }
        
        if let labelsAdded = record.labelsAdded {
            for added in labelsAdded {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", added.message.id)
                if let message = try? context.fetch(request).first {
                    for labelId in added.labelIds {
                        if let label = await findLabel(id: labelId, in: context) {
                            message.addToLabels(label)
                        }
                    }
                    message.isUnread = added.labelIds.contains("UNREAD")
                }
            }
        }
        
        if let labelsRemoved = record.labelsRemoved {
            for removed in labelsRemoved {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", removed.message.id)
                if let message = try? context.fetch(request).first {
                    for labelId in removed.labelIds {
                        if let label = await findLabel(id: labelId, in: context) {
                            message.removeFromLabels(label)
                        }
                    }
                    if removed.labelIds.contains("UNREAD") {
                        message.isUnread = false
                    }
                }
            }
        }
    }
    
    
    private func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        await conversationManager.removeDuplicateConversations(in: context)
    }
    
    private func removeDuplicateMessages(in context: NSManagedObjectContext) async {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.returnsDistinctResults = false
        
        guard let results = try? context.fetch(request) as? [[String: Any]] else { return }
        
        var seenIds = Set<String>()
        var duplicateIds = [String]()
        
        for result in results {
            if let id = result["id"] as? String {
                if seenIds.contains(id) {
                    duplicateIds.append(id)
                } else {
                    seenIds.insert(id)
                }
            }
        }
        
        for duplicateId in duplicateIds {
            let deleteRequest = Message.fetchRequest()
            deleteRequest.predicate = NSPredicate(format: "id == %@", duplicateId)
            deleteRequest.fetchLimit = 1
            
            if let duplicates = try? context.fetch(deleteRequest), let duplicate = duplicates.first {
                context.delete(duplicate)
            }
        }
        
        if !duplicateIds.isEmpty {
            do {
                try coreDataStack.save(context: context)
                print("Removed \(duplicateIds.count) duplicate messages")
            } catch {
                print("Failed to save after removing duplicates: \(error)")
                // Non-critical - continue
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}