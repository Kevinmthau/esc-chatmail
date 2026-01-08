import Foundation
import CoreData

// MARK: - Optimistic Message Updates

extension GmailSendService {

    /// Creates an optimistic local message before the actual send completes.
    /// This provides immediate feedback to the user.
    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String? = nil,
        threadId: String? = nil,
        attachments: [Attachment] = []
    ) async -> Message {
        // Pre-compute values that don't need Core Data
        let messageId = UUID().uuidString
        let snippet = String(body.prefix(120))
        let cleanedSnippet = EmailTextProcessor.createCleanSnippet(from: body, maxLength: Int.max, firstSentenceOnly: false)
        let gmThreadId = threadId ?? ""
        let hasAttachments = !attachments.isEmpty

        // Get account info for myAliases (already on main thread via @MainActor)
        let myAliases: Set<String> = {
            let accountRequest = Account.fetchRequest()
            accountRequest.fetchLimit = 1
            accountRequest.fetchBatchSize = 1
            if let account = try? viewContext.fetch(accountRequest).first {
                return Set(([account.email] + account.aliasesArray).map(normalizedEmail))
            }
            return []
        }()

        // Create the conversation using the serializer to prevent race conditions
        // Get the objectID since Conversation isn't safe to pass across threads
        let conversationID = await findOrCreateConversation(recipients: recipients, myAliases: myAliases, in: viewContext).objectID

        // Fetch conversation on main thread using the objectID
        guard let conversation = try? viewContext.existingObject(with: conversationID) as? Conversation else {
            fatalError("Failed to fetch conversation on main thread")
        }

        let message = Message(context: viewContext)
        message.id = messageId
        message.isFromMe = true
        message.internalDate = Date()
        message.snippet = snippet
        message.cleanedSnippet = cleanedSnippet
        message.gmThreadId = gmThreadId
        message.subject = subject
        message.hasAttachments = hasAttachments

        // Add attachments to message
        for attachment in attachments {
            attachment.setValue(message, forKey: "message")
            attachment.state = .queued
        }

        message.conversation = conversation

        // Update conversation to bump it to the top
        conversation.lastMessageDate = Date()
        // For sent messages, always show the reply snippet
        conversation.snippet = message.cleanedSnippet ?? message.snippet
        // IMPORTANT: do NOT set conversation.hasInbox = true here for outgoing messages

        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to save optimistic message", category: .message, error: error)
        }

        return message
    }

    /// Fetches a message by its ID (async to avoid blocking main thread).
    func fetchMessage(byID messageID: String) async -> Message? {
        await viewContext.perform { [viewContext] in
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(messageID)
            request.fetchLimit = 1
            request.fetchBatchSize = 1

            do {
                return try viewContext.fetch(request).first
            } catch {
                Log.error("Failed to fetch message", category: .message, error: error)
                return nil
            }
        }
    }

    /// Fetches a message by its ID synchronously (for use on MainActor where viewContext is safe).
    @MainActor
    func fetchMessageSync(byID messageID: String) -> Message? {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.id(messageID)
        request.fetchLimit = 1
        request.fetchBatchSize = 1

        do {
            return try viewContext.fetch(request).first
        } catch {
            Log.error("Failed to fetch message", category: .message, error: error)
            return nil
        }
    }

    /// Updates an optimistic message with the actual Gmail IDs after successful send.
    func updateOptimisticMessage(_ message: Message, with result: SendResult) {
        message.id = result.messageId
        message.gmThreadId = result.threadId

        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to update message with Gmail ID", category: .message, error: error)
        }
    }

    /// Deletes an optimistic message (used when send fails).
    func deleteOptimisticMessage(_ message: Message) {
        viewContext.delete(message)

        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to delete optimistic message", category: .message, error: error)
        }
    }

    /// Finds or creates a conversation for the given recipients.
    func findOrCreateConversation(recipients: [String], myAliases: Set<String>, in context: NSManagedObjectContext) async -> Conversation {
        // Build minimal headers for identity: From + To
        let identityHeaders = recipients.map { MessageHeader(name: "To", value: $0) }
        let identity = makeConversationIdentity(from: identityHeaders, myAliases: myAliases)

        // Use the serializer to prevent race conditions when creating conversations
        let conversation = await ConversationCreationSerializer.shared.findOrCreateConversation(for: identity, in: context)

        // Update display name for sent messages
        conversation.displayName = DisplayNameFormatter.formatGroupNames(recipients)

        return conversation
    }
}
