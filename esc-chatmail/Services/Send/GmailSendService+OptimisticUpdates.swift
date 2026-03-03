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
        attachments: [Attachment] = [],
        existingConversation: Conversation? = nil
    ) async throws -> Message {
        // Pre-compute values that don't need Core Data
        let messageId = UUID().uuidString
        let snippet = String(body.prefix(120))
        let cleanedSnippet = EmailTextProcessor.createCleanSnippet(from: body, maxLength: Int.max, firstSentenceOnly: false)
        let gmThreadId = threadId ?? ""
        let hasAttachments = !attachments.isEmpty

        let conversation: Conversation
        if let existingConversation {
            // Replies from an open chat should always attach to the currently visible
            // conversation so the optimistic bubble appears immediately in-thread.
            if existingConversation.managedObjectContext === viewContext {
                conversation = existingConversation
            } else if let fetched = try? viewContext.existingObject(with: existingConversation.objectID) as? Conversation {
                conversation = fetched
            } else {
                Log.error("Failed to resolve existing conversation for optimistic message", category: .message)
                throw SendError.conversationNotFound
            }
        } else {
            // Get account aliases only when participant-based lookup is needed.
            let myAliases: Set<String> = {
                let accountRequest = Account.fetchRequest()
                accountRequest.fetchLimit = 1
                accountRequest.fetchBatchSize = 1
                do {
                    if let account = try viewContext.fetch(accountRequest).first {
                        return Set(([account.email] + account.aliasesArray).map(normalizedEmail))
                    }
                } catch {
                    Log.error("Failed to fetch account for aliases", category: .coreData, error: error)
                }
                return []
            }()

            // Create the conversation using the serializer to prevent race conditions
            // Get the objectID since Conversation isn't safe to pass across threads
            let conversationID = try await findOrCreateConversation(recipients: recipients, myAliases: myAliases, in: viewContext).objectID

            // Fetch conversation on main thread using the objectID
            guard let fetched = try? viewContext.existingObject(with: conversationID) as? Conversation else {
                Log.error("Failed to fetch conversation on main thread", category: .message)
                throw SendError.conversationNotFound
            }
            conversation = fetched
        }

        let message = Message(context: viewContext)
        message.id = messageId
        message.isFromMe = true
        message.internalDate = Date()
        message.snippet = snippet
        message.cleanedSnippet = cleanedSnippet
        message.bodyText = body
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
        conversation.snippet = message.conversationPreviewText
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
    @MainActor
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
    @MainActor
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

    /// Handles optimistic message cleanup after a send failure.
    ///
    /// Messages with local attachments are retained and marked failed so the bubble
    /// can show an inline "Send failed" indicator. Messages without local attachments
    /// are removed to avoid leaving an unsent bubble that appears delivered.
    @MainActor
    func handleFailedOptimisticMessage(_ message: Message) {
        let localAttachments = message.attachmentsArray.filter(\.isLocalAttachment)
        guard !localAttachments.isEmpty else {
            deleteOptimisticMessage(message)
            return
        }
        markAttachmentsAsFailed(localAttachments)
    }

    /// Finds or creates a conversation for the given recipients.
    func findOrCreateConversation(recipients: [String], myAliases: Set<String>, in context: NSManagedObjectContext) async throws -> Conversation {
        // Build minimal headers for identity: From + To
        let identityHeaders = recipients.map { MessageHeader(name: "To", value: $0) }
        let identity = makeConversationIdentity(from: identityHeaders, myAliases: myAliases)

        // Use the serializer to prevent race conditions when creating conversations
        // Pass current date so sent conversations appear at top immediately (prevents UI flash)
        let conversation = try await ConversationCreationSerializer.shared.findOrCreateConversation(
            for: identity,
            initialLastMessageDate: Date(),
            in: context
        )

        // Update display name for sent messages
        conversation.displayName = DisplayNameFormatter.formatGroupNames(recipients)

        return conversation
    }
}
