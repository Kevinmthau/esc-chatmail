import Foundation
import CoreData

/// Handles updating conversation rollup data (lastMessageDate, snippet, hasInbox, etc.)
/// Extracted from ConversationManager for focused responsibility.
/// Struct is naturally Sendable since it only holds immutable references.
struct ConversationRollupUpdater: Sendable {
    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Single Conversation Rollup

    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    /// - Parameters:
    ///   - conversation: The conversation to update
    ///   - myEmail: The current user's email (must be captured before entering context.perform block)
    func updateRollups(for conversation: Conversation, myEmail: String) {
        guard conversation.managedObjectContext != nil else { return }
        guard let messages = conversation.messages else { return }

        // Phase 1: Filter draft messages and update metadata
        let nonDraftMessages = filterNonDraftMessages(messages)
        updateLastMessageMetadata(for: conversation, from: nonDraftMessages)

        // Phase 2: Update inbox status
        let (inboxMessages, hasInbox) = calculateInboxStatus(from: messages)
        let previousHasInbox = conversation.hasInbox
        conversation.hasInbox = hasInbox

        // Phase 3: Update archive state
        updateArchiveState(for: conversation, hasInbox: hasInbox, messages: messages)

        // Phase 4: Update inbox metrics
        updateInboxMetrics(for: conversation, inboxMessages: inboxMessages, previousHasInbox: previousHasInbox, totalCount: messages.count)

        // Phase 5: Update display name
        updateDisplayName(for: conversation, myEmail: myEmail)
    }

    // MARK: - Batch Rollup Operations

    /// Updates rollups for ALL conversations - expensive O(n*m) operation.
    /// Prefer updateRollupsForModified when possible.
    @MainActor
    func updateAllRollups(in context: NSManagedObjectContext) async {
        let myEmail = AuthSession.shared.userEmail ?? ""

        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50
            guard let conversations = try? context.fetch(request) else { return }

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
            }
        }
    }

    /// Updates rollups only for conversations that were modified.
    /// Much more efficient than updateAllRollups - O(k*m) where k << n.
    @MainActor
    func updateRollupsForModified(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        guard !conversationIDs.isEmpty else { return }
        let myEmail = AuthSession.shared.userEmail ?? ""

        await context.perform {
            for objectID in conversationIDs {
                if let conversation = try? context.existingObject(with: objectID) as? Conversation {
                    self.updateRollups(for: conversation, myEmail: myEmail)
                }
            }
        }
    }

    /// Updates rollups for conversations by keyHash.
    @MainActor
    func updateRollupsForConversations(
        keyHashes: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        guard !keyHashes.isEmpty else { return }
        let myEmail = AuthSession.shared.userEmail ?? ""

        await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "keyHash IN %@", keyHashes)
            request.fetchBatchSize = 50

            guard let conversations = try? context.fetch(request) else { return }

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
            }
        }
    }

    // MARK: - Private Helper Methods

    /// Filters out draft messages from the message set.
    private func filterNonDraftMessages(_ messages: Set<Message>) -> [Message] {
        messages.filter { message in
            guard let labels = message.labels else { return true }
            let isDraft = labels.contains { $0.id == "DRAFTS" }
            return !isDraft
        }
    }

    /// Updates last message date and snippet from sorted messages.
    private func updateLastMessageMetadata(for conversation: Conversation, from nonDraftMessages: [Message]) {
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
    }

    /// Calculates inbox status from all messages.
    /// Returns tuple of (inbox messages array, hasInbox flag).
    private func calculateInboxStatus(from messages: Set<Message>) -> ([Message], Bool) {
        var inboxMessages: [Message] = []

        for message in messages {
            if let labels = message.labels {
                let labelIds = labels.map { $0.id }
                let hasInbox = labelIds.contains("INBOX")
                if hasInbox {
                    inboxMessages.append(message)
                }
                Log.debug("Message \(message.id): labels=\(labelIds), hasINBOX=\(hasInbox)", category: .conversation)
            } else {
                Log.warning("Message \(message.id): could not read labels (labels nil)", category: .conversation)
            }
        }

        return (inboxMessages, !inboxMessages.isEmpty)
    }

    /// Updates archive state based on inbox status.
    /// CRITICAL: Handles archive/un-archive transitions.
    /// Sent-only conversations (user initiated, no replies yet) are NOT auto-archived.
    private func updateArchiveState(for conversation: Conversation, hasInbox: Bool, messages: Set<Message>) {
        // Check if this is a sent-only conversation (user initiated, no replies yet)
        // Note: We check both SENT label AND isFromMe because optimistic messages
        // may not have the SENT label yet (it gets added when Gmail returns the message)
        let hasSentOrFromMeMessages = messages.contains { message in
            message.isFromMe || (message.labels?.contains { $0.id == "SENT" } ?? false)
        }
        let hasReceivedMessages = messages.contains { message in
            !message.isFromMe
        }
        let isSentOnlyConversation = hasSentOrFromMeMessages && !hasReceivedMessages && !hasInbox

        if hasInbox && conversation.archivedAt != nil {
            // Un-archive: At least one message is back in inbox
            conversation.archivedAt = nil
            conversation.hidden = false
            Log.debug("Conversation \(conversation.id.uuidString): UN-ARCHIVED (hasInbox=true, archivedAt->nil)", category: .conversation)
        } else if !hasInbox && conversation.archivedAt == nil && !isSentOnlyConversation {
            // Archive only if:
            // - No INBOX messages AND
            // - Not a sent-only conversation (awaiting reply)
            conversation.archivedAt = Date()
            conversation.hidden = true
            Log.debug("Conversation \(conversation.id.uuidString): ARCHIVED (hasInbox=false, archivedAt set)", category: .conversation)
        } else if isSentOnlyConversation && conversation.archivedAt == nil {
            Log.debug("Conversation \(conversation.id.uuidString): KEPT VISIBLE (sent-only, awaiting reply)", category: .conversation)
        }

        // Keep hidden state in sync with archive state (for backward compatibility)
        // But don't hide sent-only conversations
        if hasInbox && conversation.hidden {
            conversation.hidden = false
        } else if !hasInbox && !conversation.hidden && !isSentOnlyConversation {
            conversation.hidden = true
        }
    }

    /// Updates inbox-related metrics (unread count, latest inbox date).
    private func updateInboxMetrics(
        for conversation: Conversation,
        inboxMessages: [Message],
        previousHasInbox: Bool,
        totalCount: Int
    ) {
        let hasInbox = !inboxMessages.isEmpty
        Log.debug("Conversation \(conversation.id.uuidString): hasInbox=\(hasInbox) (was \(previousHasInbox)), inboxMsgCount=\(inboxMessages.count), totalMsgCount=\(totalCount), hidden=\(conversation.hidden)", category: .conversation)

        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)

        if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
            conversation.latestInboxDate = latestInboxMessage.internalDate
        }
    }

    /// Updates display name from participants, excluding the current user.
    private func updateDisplayName(for conversation: Conversation, myEmail: String) {
        guard let participants = conversation.participants else { return }

        let normalizedMyEmail = EmailNormalizer.normalize(myEmail)

        // Log all participants for debugging
        let allParticipantEmails = participants.compactMap { $0.person?.email }
        Log.debug("Conversation \(conversation.id): All participants: \(allParticipantEmails)", category: .conversation)
        Log.debug("My email: \(myEmail) (normalized: \(normalizedMyEmail))", category: .conversation)

        // Deduplicate participants by normalized email
        var seenEmails = Set<String>()
        var names: [String] = []

        for participant in participants {
            guard let person = participant.person else { continue }
            let email = person.email
            let normalizedEmail = EmailNormalizer.normalize(email)

            // Exclude current user from display name
            if normalizedEmail == normalizedMyEmail {
                Log.debug("Excluding self: \(email)", category: .conversation)
                continue
            }

            // Skip duplicates
            guard !seenEmails.contains(normalizedEmail) else { continue }
            seenEmails.insert(normalizedEmail)

            // Use displayName, fall back to email, fall back to "Unknown"
            let name = person.displayName?.isEmpty == false ? person.displayName! : (email.isEmpty ? "Unknown" : email)
            Log.debug("Including participant: \(name)", category: .conversation)
            names.append(name)
        }

        let finalDisplayName = DisplayNameFormatter.formatGroupNames(names)
        Log.debug("Final displayName: \(finalDisplayName), snippet: \(conversation.snippet ?? "nil")", category: .conversation)
        // Ensure we never set an empty display name
        conversation.displayName = finalDisplayName.isEmpty ? "Unknown" : finalDisplayName
    }
}
