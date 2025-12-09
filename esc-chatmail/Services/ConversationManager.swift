import Foundation
import CoreData

final class ConversationManager: @unchecked Sendable {
    private let coreDataStack = CoreDataStack.shared
    
    func findOrCreateConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) async -> Conversation {
        return await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "keyHash == %@", identity.keyHash)
            request.fetchLimit = 1
            request.fetchBatchSize = 1  // Single object fetch

            if let existing = try? context.fetch(request).first {
                return existing
            }

            return self.createNewConversation(for: identity, in: context)
        }
    }
    
    private func createNewConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) -> Conversation {
        let conversation = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context) as! Conversation
        conversation.id = UUID()
        conversation.keyHash = identity.keyHash
        conversation.conversationType = identity.type
        
        // Create participants
        for email in identity.participants {
            let person = findOrCreatePerson(email: email, displayName: nil, in: context)
            let participant = NSEntityDescription.insertNewObject(forEntityName: "ConversationParticipant", into: context) as! ConversationParticipant
            participant.id = UUID()
            participant.participantRole = .normal
            participant.person = person
            participant.conversation = conversation
        }
        
        return conversation
    }
    
    func findOrCreatePerson(
        email: String,
        displayName: String?,
        in context: NSManagedObjectContext
    ) -> Person {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        request.fetchLimit = 1
        request.fetchBatchSize = 1  // Single object fetch
        
        if let existing = try? context.fetch(request).first {
            // Update display name if we have a new one and the existing one is nil
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
    
    func updateConversationRollups(for conversation: Conversation) {
        guard let context = conversation.managedObjectContext else { return }
        
        context.performAndWait {
            guard let messages = conversation.value(forKey: "messages") as? Set<Message> else { return }

            // Filter out draft messages
            let nonDraftMessages = messages.filter { message in
                if let labelsSet = message.value(forKey: "labels") as? NSSet,
                   let labels = labelsSet.allObjects as? [NSManagedObject] {
                    let isDraft = labels.contains { label in
                        (label.value(forKey: "id") as? String) == "DRAFTS"
                    }
                    return !isDraft
                }
                return true
            }

            // Update last message date and snippet (excluding drafts)
            let sortedMessages = nonDraftMessages.sorted { $0.internalDate < $1.internalDate }
            if let latestMessage = sortedMessages.last {
                conversation.lastMessageDate = latestMessage.internalDate
                // For newsletters, show subject. For personal emails or sent messages, show snippet.
                if latestMessage.isNewsletter, let subject = latestMessage.subject, !subject.isEmpty {
                    conversation.snippet = subject
                } else {
                    conversation.snippet = latestMessage.cleanedSnippet ?? latestMessage.snippet
                }
            }
            
            // Update inbox status
            var inboxMessages: [Message] = []
            for message in messages {
                if let labelsSet = message.value(forKey: "labels") as? NSSet,
                   let labels = labelsSet.allObjects as? [NSManagedObject] {
                    let hasInbox = labels.contains { label in
                        (label.value(forKey: "id") as? String) == "INBOX"
                    }
                    if hasInbox {
                        inboxMessages.append(message)
                    }
                }
            }
            
            conversation.hasInbox = !inboxMessages.isEmpty
            conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)
            
            if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
                conversation.latestInboxDate = latestInboxMessage.internalDate
            }
            
            // Update display name from participants
            if let participants = conversation.value(forKey: "participants") as? Set<ConversationParticipant> {
                let names = participants.compactMap { participant in
                    if let person = participant.value(forKey: "person") as? Person {
                        return (person.value(forKey: "displayName") as? String) ?? (person.value(forKey: "email") as? String)
                    }
                    return nil
                }
                conversation.displayName = self.formatGroupNames(names)
            }
        }
    }

    private func formatGroupNames(_ names: [String]) -> String {
        // Extract first names only
        let firstNames = names.map { name in
            // Split by space and take the first component
            let components = name.components(separatedBy: " ")
            return components.first ?? name
        }

        switch firstNames.count {
        case 0:
            return ""
        case 1:
            return firstNames[0]
        case 2:
            return "\(firstNames[0]) & \(firstNames[1])"
        case 3:
            return "\(firstNames[0]), \(firstNames[1]) & \(firstNames[2])"
        default:
            // 4 or more: "John, Jane, Bob & Alice"
            let allButLast = firstNames.dropLast()
            let last = firstNames.last!
            return "\(allButLast.joined(separator: ", ")) & \(last)"
        }
    }

    func updateAllConversationRollups(in context: NSManagedObjectContext) async {
        await context.perform { [weak self] in
            guard let self = self else { return }
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50  // Process conversations in batches
            guard let conversations = try? context.fetch(request) else { return }

            for conversation in conversations {
                self.updateConversationRollups(for: conversation)
            }
        }
    }
    
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform { [weak self] in
            guard let self = self else { return }

            // Step 1: Find duplicate keyHashes using a lightweight dictionary fetch
            // This avoids loading full Conversation objects initially
            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
            countRequest.resultType = .dictionaryResultType
            countRequest.propertiesToFetch = ["keyHash"]

            guard let results = try? context.fetch(countRequest) as? [[String: Any]] else { return }

            // Build a map of keyHash -> count
            var keyHashCounts = [String: Int]()
            for result in results {
                if let keyHash = result["keyHash"] as? String, !keyHash.isEmpty {
                    keyHashCounts[keyHash, default: 0] += 1
                }
            }

            // Get keyHashes that appear more than once
            let duplicateKeyHashes = keyHashCounts.filter { $0.value > 1 }.map { $0.key }

            guard !duplicateKeyHashes.isEmpty else {
                return
            }

            var mergedCount = 0
            var deletedObjectIDs = [NSManagedObjectID]()

            // Step 2: Process each duplicate group - fetch only the duplicates
            for keyHash in duplicateKeyHashes {
                let request = Conversation.fetchRequest()
                request.predicate = NSPredicate(format: "keyHash == %@", keyHash)
                request.returnsObjectsAsFaults = false  // We need to access properties

                guard let group = try? context.fetch(request), group.count > 1 else { continue }

                let winner = self.selectWinnerConversation(from: group)
                let losers = group.filter { $0 != winner }

                for loser in losers {
                    self.mergeConversation(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 {
                self.coreDataStack.saveIfNeeded(context: context)

                // Merge deletions to view context
                if !deletedObjectIDs.isEmpty {
                    let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext]
                    )
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                print("📊 Merged \(mergedCount) duplicate conversations in \(String(format: "%.3f", duration))s")
            }
        }
    }
    
    private func selectWinnerConversation(from group: [Conversation]) -> Conversation {
        return group.max { (a, b) in
            let aMessages = a.value(forKey: "messages") as? Set<Message>
            let bMessages = b.value(forKey: "messages") as? Set<Message>
            let aCount = aMessages?.count ?? 0
            let bCount = bMessages?.count ?? 0
            if aCount != bCount { return aCount < bCount }
            let aDate = a.value(forKey: "lastMessageDate") as? Date ?? .distantPast
            let bDate = b.value(forKey: "lastMessageDate") as? Date ?? .distantPast
            return aDate < bDate
        }!
    }
    
    private func mergeConversation(from loser: Conversation, into winner: Conversation) {
        // Reassign all messages from loser to winner
        if let messages = loser.value(forKey: "messages") as? Set<Message> {
            for message in messages {
                message.setValue(winner, forKey: "conversation")
            }
        }
        
        // Merge rollup data
        winner.lastMessageDate = max(winner.lastMessageDate ?? .distantPast,
                                    loser.lastMessageDate ?? .distantPast)
        
        if winner.snippet == nil || 
           (loser.lastMessageDate ?? .distantPast) > (winner.lastMessageDate ?? .distantPast) {
            winner.snippet = loser.snippet
        }
        
        winner.hasInbox = winner.hasInbox || loser.hasInbox
        winner.inboxUnreadCount += loser.inboxUnreadCount
        
        if let loserLatestInboxDate = loser.value(forKey: "latestInboxDate") as? Date {
            let winnerLatestInboxDate = winner.value(forKey: "latestInboxDate") as? Date ?? .distantPast
            winner.setValue(max(winnerLatestInboxDate, loserLatestInboxDate), forKey: "latestInboxDate")
        }
        
        // Preserve pinned status
        let winnerPinned = winner.value(forKey: "pinned") as? Bool ?? false
        let loserPinned = loser.value(forKey: "pinned") as? Bool ?? false
        winner.setValue(winnerPinned || loserPinned, forKey: "pinned")
    }
    
    func createConversationIdentity(from headers: ProcessedHeaders, myAliases: Set<String>) -> ConversationIdentity {
        var participants = Set<String>()
        
        // Add sender
        if let fromEmail = EmailNormalizer.extractEmail(from: headers.from ?? "") {
            participants.insert(normalizedEmail(fromEmail))
        }
        
        // Add recipients
        for recipient in headers.to {
            participants.insert(recipient.email)
        }
        for recipient in headers.cc {
            participants.insert(recipient.email)
        }
        
        // Create identity using the existing global function
        let messageHeaders = createMessageHeaders(from: headers)
        return makeConversationIdentity(from: messageHeaders, myAliases: myAliases)
    }
    
    private func createMessageHeaders(from headers: ProcessedHeaders) -> [MessageHeader] {
        var messageHeaders: [MessageHeader] = []
        
        if let from = headers.from {
            messageHeaders.append(MessageHeader(name: "From", value: from))
        }
        
        for recipient in headers.to {
            let value = recipient.displayName != nil ? "\(recipient.displayName!) <\(recipient.email)>" : recipient.email
            messageHeaders.append(MessageHeader(name: "To", value: value))
        }
        
        for recipient in headers.cc {
            let value = recipient.displayName != nil ? "\(recipient.displayName!) <\(recipient.email)>" : recipient.email
            messageHeaders.append(MessageHeader(name: "Cc", value: value))
        }
        
        return messageHeaders
    }
}