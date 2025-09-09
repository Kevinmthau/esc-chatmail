import Foundation
import CoreData

class ConversationManager {
    private let coreDataStack = CoreDataStack.shared
    
    func findOrCreateConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) async -> Conversation {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "keyHash == %@", identity.keyHash)
        request.fetchLimit = 1
        
        if let existing = try? context.fetch(request).first {
            return existing
        }
        
        return createNewConversation(for: identity, in: context)
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
        guard let messages = conversation.messages else { return }
        
        // Update last message date and snippet
        if let latestMessage = messages.max(by: { $0.internalDate < $1.internalDate }) {
            conversation.lastMessageDate = latestMessage.internalDate
            conversation.snippet = latestMessage.cleanedSnippet ?? latestMessage.snippet
        }
        
        // Update inbox status
        let inboxMessages = messages.filter { message in
            guard let labels = message.labels else { return false }
            return labels.contains { $0.id == "INBOX" }
        }
        
        conversation.hasInbox = !inboxMessages.isEmpty
        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)
        
        if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
            conversation.latestInboxDate = latestInboxMessage.internalDate
        }
        
        // Update display name from participants
        if let participants = conversation.participants {
            let names = participants.compactMap { $0.person?.displayName ?? $0.person?.email }
            conversation.displayName = names.joined(separator: ", ")
        }
    }
    
    func updateAllConversationRollups(in context: NSManagedObjectContext) async {
        let request = Conversation.fetchRequest()
        guard let conversations = try? context.fetch(request) else { return }
        
        for conversation in conversations {
            updateConversationRollups(for: conversation)
        }
    }
    
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        let request = Conversation.fetchRequest()
        guard let conversations = try? context.fetch(request) else { return }
        
        // Group conversations by keyHash
        var groupedByKey = [String: [Conversation]]()
        for conversation in conversations {
            groupedByKey[conversation.keyHash, default: []].append(conversation)
        }
        
        var mergedCount = 0
        
        // Process each group with duplicates
        for (_, group) in groupedByKey where group.count > 1 {
            let winner = selectWinnerConversation(from: group)
            let losers = group.filter { $0 != winner }
            
            for loser in losers {
                mergeConversation(from: loser, into: winner)
                context.delete(loser)
                mergedCount += 1
            }
        }
        
        if mergedCount > 0 {
            coreDataStack.save(context: context)
            print("Merged \(mergedCount) duplicate conversations")
        }
    }
    
    private func selectWinnerConversation(from group: [Conversation]) -> Conversation {
        return group.max { (a, b) in
            let aCount = a.messages?.count ?? 0
            let bCount = b.messages?.count ?? 0
            if aCount != bCount { return aCount < bCount }
            return (a.lastMessageDate ?? .distantPast) < (b.lastMessageDate ?? .distantPast)
        }!
    }
    
    private func mergeConversation(from loser: Conversation, into winner: Conversation) {
        // Reassign all messages from loser to winner
        if let messages = loser.messages {
            for message in messages {
                message.conversation = winner
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
        
        if let loserLatestInboxDate = loser.latestInboxDate {
            winner.latestInboxDate = max(winner.latestInboxDate ?? .distantPast, loserLatestInboxDate)
        }
        
        // Preserve pinned status
        winner.pinned = winner.pinned || loser.pinned
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