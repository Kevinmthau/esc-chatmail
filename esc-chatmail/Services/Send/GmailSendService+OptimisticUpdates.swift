import Foundation
import CoreData

// MARK: - Optimistic Message Updates

extension GmailSendService {

    /// Creates an optimistic local message before the actual send completes.
    /// This provides immediate feedback to the user.
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String? = nil,
        threadId: String? = nil,
        attachments: [Attachment] = []
    ) async -> Message {
        let message = Message(context: viewContext)
        message.id = UUID().uuidString
        message.isFromMe = true
        message.internalDate = Date()
        message.snippet = String(body.prefix(120))
        // Sent messages should show full content without any length limit
        message.cleanedSnippet = EmailTextProcessor.createCleanSnippet(from: body, maxLength: Int.max, firstSentenceOnly: false)
        message.gmThreadId = threadId ?? ""
        message.subject = subject
        message.hasAttachments = !attachments.isEmpty

        // Add attachments to message
        for attachment in attachments {
            attachment.setValue(message, forKey: "message")
            attachment.state = .queued
        }

        // Get account info for myAliases
        let accountRequest = Account.fetchRequest()
        accountRequest.fetchLimit = 1
        accountRequest.fetchBatchSize = 1

        let myAliases: Set<String>
        if let account = try? viewContext.fetch(accountRequest).first {
            myAliases = Set(([account.email] + account.aliasesArray).map(normalizedEmail))
        } else {
            myAliases = []
        }

        // Create the conversation using the serializer to prevent race conditions
        let conversation = await findOrCreateConversation(recipients: recipients, myAliases: myAliases, in: viewContext)
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

    /// Fetches a message by its ID.
    func fetchMessage(byID messageID: String) -> Message? {
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
