import Foundation
import CoreData
import Combine

class SyncEngine: ObservableObject {
    static let shared = SyncEngine()
    
    @Published var isSyncing = false
    @Published var syncProgress: Double = 0.0
    @Published var syncStatus: String = ""
    
    private let apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    private let messageProcessor = MessageProcessor()
    private let htmlContentHandler = HTMLContentHandler()
    private let conversationManager = ConversationManager()
    private var myAliases: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    
    private init() {}
    
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
            
            var allMessageIds: [String] = []
            var pageToken: String? = nil
            
            repeat {
                let response = try await apiClient.listMessages(pageToken: pageToken, maxResults: 500)
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
            coreDataStack.save(context: context)
            
            // Update account's historyId in the main context
            await updateAccountHistoryId(profile.historyId)
            
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
        guard let account = try await fetchAccount() else { return }
        
        // Extract account properties while still on the main thread
        let historyId = await MainActor.run { account.historyId }
        let email = await MainActor.run { account.email }
        let aliases = await MainActor.run { account.aliasesArray }
        
        guard let historyId = historyId else {
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
                    for record in history {
                        await processHistoryRecord(record, in: context)
                    }
                }
                
                if let newHistoryId = response.historyId {
                    latestHistoryId = newHistoryId
                }
                
                pageToken = response.nextPageToken
            } while pageToken != nil
            
            await updateConversationRollups(in: context)
            await removeDuplicateConversations(in: context)
            
            // Update account's historyId in the proper context
            await updateAccountHistoryId(latestHistoryId)
            
            coreDataStack.save(context: context)
            
            await MainActor.run {
                self.syncStatus = "Sync complete"
                self.isSyncing = false
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
        // Process the Gmail message
        guard let processedMessage = messageProcessor.processGmailMessage(gmailMessage, myAliases: myAliases, in: context) else {
            return
        }
        
        // Check for duplicates
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        if (try? context.fetch(request).first) != nil {
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
    
    private func fetchAccount() async throws -> Account? {
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
    
    private func updateAccountHistoryId(_ historyId: String) async {
        await withCheckedContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = Account.fetchRequest()
                request.fetchLimit = 1
                if let account = try? context.fetch(request).first {
                    account.historyId = historyId
                    self.coreDataStack.save(context: context)
                }
                continuation.resume()
            }
        } as Void
    }
    
    func updateConversationRollups(in context: NSManagedObjectContext) async {
        await conversationManager.updateAllConversationRollups(in: context)
    }
    
    private func processHistoryRecord(_ record: HistoryRecord, in context: NSManagedObjectContext) async {
        if let messagesAdded = record.messagesAdded {
            for added in messagesAdded {
                await saveMessage(added.message, in: context)
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
            coreDataStack.save(context: context)
            print("Removed \(duplicateIds.count) duplicate messages")
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