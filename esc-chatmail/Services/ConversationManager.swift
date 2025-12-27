import Foundation
import CoreData

final class ConversationManager: @unchecked Sendable {
    private let coreDataStack = CoreDataStack.shared

    /// Finds an ACTIVE (non-archived) conversation for the given participants, or creates a new one.
    ///
    /// Archive-aware lookup:
    /// 1. Look for conversations with matching participantHash WHERE archivedAt IS NULL
    /// 2. If found, return the existing active conversation
    /// 3. If not found (all archived or none exist), create a NEW conversation
    ///
    /// This ensures that when a user archives a conversation and later receives a new email
    /// from the same person, it appears as a fresh conversation without the old history.
    func findOrCreateConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) async -> Conversation {
        return await context.perform {
            // Look for an ACTIVE conversation with these participants
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(
                format: "participantHash == %@ AND archivedAt == nil",
                identity.participantHash
            )
            request.fetchLimit = 1
            request.fetchBatchSize = 1

            if let existing = try? context.fetch(request).first {
                print("📬 [ConversationManager] Found active conversation for participants: \(identity.participants)")
                return existing
            }

            // No active conversation found - create a new one
            // This happens when:
            // 1. First message from these participants
            // 2. All previous conversations with these participants are archived
            print("📬 [ConversationManager] Creating new conversation for participants: \(identity.participants)")
            return ConversationFactory.create(for: identity, in: context)
        }
    }

    /// Delegates to PersonFactory for consistent person creation
    func findOrCreatePerson(
        email: String,
        displayName: String?,
        in context: NSManagedObjectContext
    ) -> Person {
        PersonFactory.findOrCreate(email: email, displayName: displayName, in: context)
    }
    
    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    /// - Parameters:
    ///   - conversation: The conversation to update
    ///   - myEmail: The current user's email (must be captured before entering context.perform block due to @MainActor isolation)
    func updateConversationRollups(for conversation: Conversation, myEmail: String) {
        guard conversation.managedObjectContext != nil else { return }

        // Note: This method assumes it's called from within context.perform or performAndWait
        // Do not add performAndWait here as it causes nested blocking when called from updateAllConversationRollups
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
        let previousHasInbox = conversation.hasInbox
        for message in messages {
            if let labelsSet = message.value(forKey: "labels") as? NSSet,
               let labels = labelsSet.allObjects as? [NSManagedObject] {
                let labelIds = labels.compactMap { $0.value(forKey: "id") as? String }
                let hasInbox = labelIds.contains("INBOX")
                if hasInbox {
                    inboxMessages.append(message)
                }
                // Debug: Log message label info during rollup
                if let msgId = message.value(forKey: "id") as? String {
                    print("📬 [ConversationRollup] Message \(msgId): labels=\(labelIds), hasINBOX=\(hasInbox)")
                }
            } else {
                // Debug: Log if labels aren't accessible
                if let msgId = message.value(forKey: "id") as? String {
                    print("⚠️ [ConversationRollup] Message \(msgId): could not read labels (labels nil or not NSSet)")
                }
            }
        }

        let newHasInbox = !inboxMessages.isEmpty
        conversation.hasInbox = newHasInbox

        // CRITICAL: Handle archive state changes
        // When ALL messages lose INBOX label (from Gmail), set archivedAt
        // When ANY message gets INBOX label back, clear archivedAt (un-archive)
        if newHasInbox && conversation.archivedAt != nil {
            // Un-archive: At least one message is back in inbox
            conversation.archivedAt = nil
            conversation.hidden = false
            print("📬 [ConversationRollup] Conversation \(conversation.id.uuidString): UN-ARCHIVED (hasInbox=true, archivedAt->nil)")
        } else if !newHasInbox && conversation.archivedAt == nil {
            // Archive: All messages have lost INBOX label
            conversation.archivedAt = Date()
            conversation.hidden = true
            print("📬 [ConversationRollup] Conversation \(conversation.id.uuidString): ARCHIVED (hasInbox=false, archivedAt set)")
        }

        // Keep hidden state in sync with archive state (for backward compatibility)
        if newHasInbox && conversation.hidden {
            conversation.hidden = false
        } else if !newHasInbox && !conversation.hidden {
            conversation.hidden = true
        }

        // Log rollup result
        print("📬 [ConversationRollup] Conversation \(conversation.id.uuidString): hasInbox=\(newHasInbox) (was \(previousHasInbox)), inboxMsgCount=\(inboxMessages.count), totalMsgCount=\(messages.count), hidden=\(conversation.hidden)")
        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)

        if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
            conversation.latestInboxDate = latestInboxMessage.internalDate
        }

        // Update display name from participants (excluding the current user)
        if let participants = conversation.value(forKey: "participants") as? Set<ConversationParticipant> {
            let normalizedMyEmail = EmailNormalizer.normalize(myEmail)

            // Log all participants for debugging
            let allParticipantEmails = participants.compactMap { participant -> String? in
                guard let person = participant.value(forKey: "person") as? Person else { return nil }
                return person.value(forKey: "email") as? String
            }
            print("[ConversationManager] Conversation \(conversation.id): All participants: \(allParticipantEmails)")
            print("[ConversationManager] My email: \(myEmail) (normalized: \(normalizedMyEmail))")

            // Deduplicate participants by normalized email
            var seenEmails = Set<String>()
            var names: [String] = []
            for participant in participants {
                guard let person = participant.value(forKey: "person") as? Person else { continue }
                guard let email = person.value(forKey: "email") as? String else { continue }

                let normalizedEmail = EmailNormalizer.normalize(email)

                // Exclude current user from display name
                if normalizedEmail == normalizedMyEmail {
                    print("[ConversationManager] Excluding self: \(email)")
                    continue
                }

                // Skip duplicates
                guard !seenEmails.contains(normalizedEmail) else { continue }
                seenEmails.insert(normalizedEmail)

                let name = (person.value(forKey: "displayName") as? String) ?? email
                print("[ConversationManager] Including participant: \(name)")
                names.append(name)
            }
            let finalDisplayName = self.formatGroupNames(names)
            print("[ConversationManager] Final displayName: \(finalDisplayName), snippet: \(conversation.snippet ?? "nil")")
            conversation.displayName = finalDisplayName
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

    /// Updates rollups for ALL conversations - expensive O(n*m) operation.
    /// Prefer updateRollupsForModifiedConversations when possible.
    @MainActor
    func updateAllConversationRollups(in context: NSManagedObjectContext) async {
        // Capture user email on main actor before entering context.perform
        let myEmail = AuthSession.shared.userEmail ?? ""

        await context.perform { [weak self] in
            guard let self = self else { return }
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50  // Process conversations in batches
            guard let conversations = try? context.fetch(request) else { return }

            for conversation in conversations {
                self.updateConversationRollups(for: conversation, myEmail: myEmail)
            }
        }
    }

    /// Updates rollups only for conversations that were modified.
    /// Much more efficient than updateAllConversationRollups - O(k*m) where k << n.
    @MainActor
    func updateRollupsForModifiedConversations(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        guard !conversationIDs.isEmpty else { return }

        // Capture user email on main actor before entering context.perform
        let myEmail = AuthSession.shared.userEmail ?? ""

        await context.perform { [weak self] in
            guard let self = self else { return }

            for objectID in conversationIDs {
                if let conversation = try? context.existingObject(with: objectID) as? Conversation {
                    self.updateConversationRollups(for: conversation, myEmail: myEmail)
                }
            }
        }
    }

    /// Updates rollups for conversations by keyHash - useful when you have keyHashes but not objectIDs.
    @MainActor
    func updateRollupsForConversations(
        keyHashes: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        guard !keyHashes.isEmpty else { return }

        // Capture user email on main actor before entering context.perform
        let myEmail = AuthSession.shared.userEmail ?? ""

        await context.perform { [weak self] in
            guard let self = self else { return }

            // Batch fetch conversations by keyHash
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "keyHash IN %@", keyHashes)
            request.fetchBatchSize = 50

            guard let conversations = try? context.fetch(request) else { return }

            for conversation in conversations {
                self.updateConversationRollups(for: conversation, myEmail: myEmail)
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
    
    /// Creates a conversation identity using Gmail threadId as the primary key.
    /// This ensures stable conversation grouping that matches Gmail's threading.
    /// - Parameters:
    ///   - headers: Processed message headers
    ///   - gmThreadId: Gmail's thread ID for stable grouping
    ///   - myAliases: Set of user's email aliases to exclude from participants
    func createConversationIdentity(from headers: ProcessedHeaders, gmThreadId: String, myAliases: Set<String>) -> ConversationIdentity {
        // Create identity using the global function with threadId
        let messageHeaders = createMessageHeaders(from: headers)
        return makeConversationIdentity(from: messageHeaders, gmThreadId: gmThreadId, myAliases: myAliases)
    }

    /// Legacy function for backward compatibility - calls new function with empty threadId
    /// @deprecated Use createConversationIdentity(from:gmThreadId:myAliases:) instead
    func createConversationIdentity(from headers: ProcessedHeaders, myAliases: Set<String>) -> ConversationIdentity {
        return createConversationIdentity(from: headers, gmThreadId: "", myAliases: myAliases)
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

        // Note: BCC is intentionally excluded from headers for identity creation
        // to ensure consistent behavior (BCC is not included in identity or display)

        if let listId = headers.listId {
            messageHeaders.append(MessageHeader(name: "List-Id", value: listId))
        }

        return messageHeaders
    }
}