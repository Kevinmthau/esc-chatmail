import Foundation
import Combine
import CoreData

@MainActor
final class GmailSendService: ObservableObject {
    private let apiClient: GmailAPIClient
    private let authSession: AuthSession
    private let viewContext: NSManagedObjectContext

    struct SendResult {
        let messageId: String
        let threadId: String
    }

    struct AttachmentInfo: Sendable {
        let localURL: String?
        let filename: String
        let mimeType: String
    }

    enum SendError: LocalizedError {
        case invalidMimeData
        case apiError(String)
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .invalidMimeData:
                return "Failed to create message data"
            case .apiError(let message):
                return message
            case .authenticationFailed:
                return "Authentication failed"
            }
        }
    }

    init(
        viewContext: NSManagedObjectContext,
        apiClient: GmailAPIClient? = nil,
        authSession: AuthSession? = nil
    ) {
        self.viewContext = viewContext
        self.apiClient = apiClient ?? .shared
        self.authSession = authSession ?? .shared
    }
    
    nonisolated func sendNew(to recipients: [String], body: String, subject: String? = nil, attachmentInfos: [AttachmentInfo] = []) async throws -> SendResult {
        let (fromEmail, fromName) = await MainActor.run { (authSession.userEmail, authSession.userName) }
        guard let fromEmail = fromEmail else {
            throw SendError.authenticationFailed
        }

        let attachmentData = try await prepareAttachmentInfos(attachmentInfos)
        let mimeData = MimeBuilder.buildNew(
            to: recipients,
            from: fromEmail,
            fromName: fromName,
            body: body,
            subject: subject,
            attachments: attachmentData
        )
        
        let result = try await sendMessage(mimeData: mimeData, threadId: nil)

        // Attachment state updates are now handled in attachmentToInfo()

        return result
    }
    
    nonisolated func sendReply(
        to recipients: [String],
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage? = nil,
        attachmentInfos: [AttachmentInfo] = []
    ) async throws -> SendResult {
        let (fromEmail, fromName) = await MainActor.run { (authSession.userEmail, authSession.userName) }
        guard let fromEmail = fromEmail else {
            throw SendError.authenticationFailed
        }

        let attachmentData = try await prepareAttachmentInfos(attachmentInfos)
        let mimeData = MimeBuilder.buildReply(
            to: recipients,
            from: fromEmail,
            fromName: fromName,
            body: body,
            subject: subject,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage,
            attachments: attachmentData
        )
        
        let result = try await sendMessage(mimeData: mimeData, threadId: threadId)

        // Attachment state updates are now handled in attachmentToInfo()

        return result
    }
    
    private nonisolated func prepareAttachmentInfos(_ attachmentInfos: [AttachmentInfo]) async throws -> [AttachmentData] {
        var attachmentData: [AttachmentData] = []

        for info in attachmentInfos {
            guard let data = AttachmentPaths.loadData(from: info.localURL) else {
                throw SendError.apiError("Failed to load attachment: \(info.filename)")
            }

            attachmentData.append(AttachmentData(
                data: data,
                filename: info.filename,
                mimeType: info.mimeType
            ))
        }

        return attachmentData
    }

    // Helper function to convert Attachment to AttachmentInfo
    func attachmentToInfo(_ attachment: Attachment) -> AttachmentInfo {
        // Update attachment state to uploading (will be marked as uploaded after successful send)
        attachment.state = .uploading

        return AttachmentInfo(
            localURL: attachment.value(forKey: "localURL") as? String,
            filename: (attachment.value(forKey: "filename") as? String) ?? "attachment",
            mimeType: (attachment.value(forKey: "mimeType") as? String) ?? "application/octet-stream"
        )
    }

    // Helper function to mark attachments as uploaded
    func markAttachmentsAsUploaded(_ attachments: [Attachment]) {
        for attachment in attachments {
            attachment.state = .uploaded
        }
        do {
            try CoreDataStack.shared.save(context: viewContext)
        } catch {
            Log.error("Failed to save attachment state", category: .attachment, error: error)
        }
    }

    // Helper function to mark attachments as failed
    func markAttachmentsAsFailed(_ attachments: [Attachment]) {
        for attachment in attachments {
            attachment.state = .failed
        }
        do {
            try CoreDataStack.shared.save(context: viewContext)
        } catch {
            Log.error("Failed to save attachment state", category: .attachment, error: error)
        }
    }
    
    private nonisolated func sendMessage(mimeData: Data, threadId: String?) async throws -> SendResult {
        Log.debug("Sending MIME message (\(mimeData.count) bytes)", category: .api)

        let rawMessage = MimeBuilder.base64UrlEncode(mimeData)

        var requestBody: [String: Any] = ["raw": rawMessage]
        if let threadId = threadId {
            requestBody["threadId"] = threadId
        }

        let accessToken = try await authSession.withFreshToken()

        guard let url = URL(string: APIEndpoints.sendMessage()) else {
            throw SendError.apiError("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw SendError.invalidMimeData
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SendError.apiError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw SendError.authenticationFailed
        }

        Log.debug("Response status: \(httpResponse.statusCode)", category: .api)

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SendError.apiError("Failed to send message: \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = json["id"] as? String,
              let returnedThreadId = json["threadId"] as? String else {
            throw SendError.apiError("Invalid response format")
        }

        Log.info("Message sent - ID: \(messageId)", category: .api)

        return SendResult(messageId: messageId, threadId: returnedThreadId)
    }
    
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
        accountRequest.fetchBatchSize = 1  // Single object fetch

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
    
    func fetchMessage(byID messageID: String) -> Message? {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageID)
        request.fetchLimit = 1
        request.fetchBatchSize = 1  // Single object fetch

        do {
            return try viewContext.fetch(request).first
        } catch {
            Log.error("Failed to fetch message", category: .message, error: error)
            return nil
        }
    }

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
    
    private func findOrCreateConversation(recipients: [String], myAliases: Set<String>, in context: NSManagedObjectContext) async -> Conversation {
        // Build minimal headers for identity: From + To
        let identityHeaders = recipients.map { MessageHeader(name: "To", value: $0) }
        let identity = makeConversationIdentity(from: identityHeaders, myAliases: myAliases)

        // Use the serializer to prevent race conditions when creating conversations
        let conversation = await ConversationCreationSerializer.shared.findOrCreateConversation(for: identity, in: context)

        // Update display name for sent messages
        conversation.displayName = formatGroupNames(recipients)

        return conversation
    }

    private nonisolated func formatGroupNames(_ names: [String]) -> String {
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
}