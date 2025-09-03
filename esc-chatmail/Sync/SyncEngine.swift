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
    private var conversationGrouper: ConversationGrouper?
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
            
            conversationGrouper = ConversationGrouper(myEmail: profile.emailAddress, aliases: aliases)
            
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
        
        // Initialize conversation grouper with stored aliases
        conversationGrouper = ConversationGrouper(myEmail: email, aliases: aliases)
        
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
    
    private func saveMessage(_ gmailMessage: GmailMessage, in context: NSManagedObjectContext) async {
        guard let payload = gmailMessage.payload,
              let headers = payload.headers,
              let grouper = conversationGrouper else { return }
        
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", gmailMessage.id)
        if (try? context.fetch(request).first) != nil {
            return
        }
        
        let (conversationKey, conversationType, participants) = grouper.computeConversationKey(from: headers)
        
        let conversation = await findOrCreateConversation(
            keyHash: conversationKey,
            type: conversationType,
            participants: participants,
            in: context
        )
        
        let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context) as! Message
        message.id = gmailMessage.id
        message.gmThreadId = gmailMessage.threadId ?? ""
        message.snippet = gmailMessage.snippet
        message.conversation = conversation
        
        if let internalDateStr = gmailMessage.internalDate,
           let internalDateMs = Double(internalDateStr) {
            message.internalDate = Date(timeIntervalSince1970: internalDateMs / 1000)
        } else {
            message.internalDate = Date()
        }
        
        for header in headers {
            switch header.name.lowercased() {
            case "subject":
                message.subject = header.value
            case "from":
                message.isFromMe = grouper.isFromMe(header.value)
                await saveParticipant(from: header.value, kind: .from, for: message, in: context)
            case "to":
                await saveParticipants(from: header.value, kind: .to, for: message, in: context)
            case "cc":
                await saveParticipants(from: header.value, kind: .cc, for: message, in: context)
            case "bcc":
                await saveParticipants(from: header.value, kind: .bcc, for: message, in: context)
            default:
                break
            }
        }
        
        if let labelIds = gmailMessage.labelIds {
            message.isUnread = labelIds.contains("UNREAD")
            
            for labelId in labelIds {
                if let label = await findLabel(id: labelId, in: context) {
                    message.addToLabels(label)
                }
            }
        }
        
        if let bodyHtml = extractHTMLBody(from: payload) {
            let fileURL = saveHTMLToFile(html: bodyHtml, messageId: gmailMessage.id)
            message.bodyStorageURI = fileURL?.absoluteString
        }
        
        message.hasAttachments = hasAttachments(in: payload)
        
        // Update conversation's lastMessageDate to bump it to the top
        if conversation.lastMessageDate == nil || message.internalDate > conversation.lastMessageDate! {
            conversation.lastMessageDate = message.internalDate
            conversation.snippet = message.snippet
        }
    }
    
    private func saveParticipant(from headerValue: String, kind: ParticipantKind, for message: Message, in context: NSManagedObjectContext) async {
        guard let email = EmailNormalizer.extractEmail(from: headerValue) else { return }
        let normalizedEmail = EmailNormalizer.normalize(email)
        let displayName = EmailNormalizer.extractDisplayName(from: headerValue)
        
        let person = await findOrCreatePerson(email: normalizedEmail, displayName: displayName, in: context)
        
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
    
    private func findOrCreatePerson(email: String, displayName: String?, in context: NSManagedObjectContext) async -> Person {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        
        if let existing = try? context.fetch(request).first {
            if displayName != nil && existing.displayName == nil {
                existing.displayName = displayName
            }
            return existing
        }
        
        let person = NSEntityDescription.insertNewObject(forEntityName: "Person", into: context) as! Person
        person.id = UUID()
        person.email = email
        person.displayName = displayName
        return person
    }
    
    private func findOrCreateConversation(keyHash: String, type: ConversationType, participants: Set<String>, in context: NSManagedObjectContext) async -> Conversation {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "keyHash == %@", keyHash)
        
        if let existing = try? context.fetch(request).first {
            return existing
        }
        
        let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context) as! Conversation
        conversation.id = UUID()
        conversation.keyHash = keyHash
        conversation.conversationType = type
        
        for email in participants {
            let person = await findOrCreatePerson(email: email, displayName: nil, in: context)
            let participant = NSEntityDescription.insertNewObject(forEntityName: "ConversationParticipant", into: context) as! ConversationParticipant
            participant.id = UUID()
            participant.participantRole = .normal
            participant.person = person
            participant.conversation = conversation
        }
        
        return conversation
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
    
    private func updateConversationRollups(in context: NSManagedObjectContext) async {
        let request = Conversation.fetchRequest()
        guard let conversations = try? context.fetch(request) else { return }
        
        for conversation in conversations {
            guard let messages = conversation.messages else { continue }
            
            if let latestMessage = messages.max(by: { $0.internalDate < $1.internalDate }) {
                conversation.lastMessageDate = latestMessage.internalDate
                conversation.snippet = latestMessage.snippet
            }
            
            let inboxMessages = messages.filter { message in
                guard let labels = message.labels else { return false }
                return labels.contains { $0.id == "INBOX" }
            }
            
            conversation.hasInbox = !inboxMessages.isEmpty
            conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)
            
            if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
                conversation.latestInboxDate = latestInboxMessage.internalDate
            }
            
            if let participants = conversation.participants {
                let names = participants.compactMap { $0.person?.displayName ?? $0.person?.email }
                conversation.displayName = names.joined(separator: ", ")
            }
        }
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
    
    private func extractHTMLBody(from part: MessagePart) -> String? {
        if part.mimeType == "text/html", let data = part.body?.data {
            let base64String = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            
            var paddedBase64 = base64String
            let remainder = base64String.count % 4
            if remainder > 0 {
                paddedBase64 = base64String + String(repeating: "=", count: 4 - remainder)
            }
            
            guard let decodedData = Data(base64Encoded: paddedBase64) else {
                print("Failed to decode Base64 for message part")
                return nil
            }
            
            return String(data: decodedData, encoding: .utf8)
        }
        
        if let parts = part.parts {
            for subpart in parts {
                if let html = extractHTMLBody(from: subpart) {
                    return html
                }
            }
        }
        
        return nil
    }
    
    private func saveHTMLToFile(html: String, messageId: String) -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let messagesDir = documentsPath.appendingPathComponent("Messages")
        
        try? FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        
        let fileURL = messagesDir.appendingPathComponent("\(messageId).html")
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        
        return fileURL
    }
    
    private func hasAttachments(in part: MessagePart) -> Bool {
        if part.body?.attachmentId != nil {
            return true
        }
        
        if let parts = part.parts {
            return parts.contains { hasAttachments(in: $0) }
        }
        
        return false
    }
    
    private func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["keyHash", "id"]
        request.returnsDistinctResults = false
        
        guard let results = try? context.fetch(request) as? [[String: Any]] else { return }
        
        var seenKeys = [String: UUID]()
        var conversationsToMerge = [(keep: UUID, delete: UUID)]()
        
        for result in results {
            if let keyHash = result["keyHash"] as? String,
               let id = result["id"] as? UUID {
                if let existingId = seenKeys[keyHash] {
                    // Found duplicate - mark for merging
                    conversationsToMerge.append((keep: existingId, delete: id))
                } else {
                    seenKeys[keyHash] = id
                }
            }
        }
        
        // Merge duplicates
        for (keepId, deleteId) in conversationsToMerge {
            let keepRequest = Conversation.fetchRequest()
            keepRequest.predicate = NSPredicate(format: "id == %@", keepId as CVarArg)
            
            let deleteRequest = Conversation.fetchRequest()
            deleteRequest.predicate = NSPredicate(format: "id == %@", deleteId as CVarArg)
            
            if let keepConv = try? context.fetch(keepRequest).first,
               let deleteConv = try? context.fetch(deleteRequest).first {
                
                // Move all messages from delete to keep
                if let messages = deleteConv.messages {
                    for message in messages {
                        message.conversation = keepConv
                    }
                }
                
                // Update lastMessageDate if needed
                if let deleteDate = deleteConv.lastMessageDate,
                   keepConv.lastMessageDate == nil || deleteDate > keepConv.lastMessageDate! {
                    keepConv.lastMessageDate = deleteDate
                    keepConv.snippet = deleteConv.snippet
                }
                
                // Merge inbox status
                if deleteConv.hasInbox {
                    keepConv.hasInbox = true
                }
                keepConv.inboxUnreadCount = max(keepConv.inboxUnreadCount, deleteConv.inboxUnreadCount)
                
                // Delete the duplicate
                context.delete(deleteConv)
            }
        }
        
        if !conversationsToMerge.isEmpty {
            coreDataStack.save(context: context)
            print("Merged \(conversationsToMerge.count) duplicate conversations")
        }
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