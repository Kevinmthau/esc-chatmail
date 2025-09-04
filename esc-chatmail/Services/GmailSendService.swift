import Foundation
import Combine
import CoreData

final class GmailSendService: ObservableObject {
    private let apiClient = GmailAPIClient.shared
    private let authSession = AuthSession.shared
    private let viewContext: NSManagedObjectContext
    
    struct SendResult {
        let messageId: String
        let threadId: String
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
    
    init(viewContext: NSManagedObjectContext) {
        self.viewContext = viewContext
    }
    
    func sendNew(to recipients: [String], body: String) async throws -> SendResult {
        guard let fromEmail = authSession.userEmail else {
            throw SendError.authenticationFailed
        }
        
        let mimeData = MimeBuilder.buildNew(
            to: recipients,
            from: fromEmail,
            body: body
        )
        
        return try await sendMessage(mimeData: mimeData, threadId: nil)
    }
    
    func sendReply(
        to recipients: [String],
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String]
    ) async throws -> SendResult {
        guard let fromEmail = authSession.userEmail else {
            throw SendError.authenticationFailed
        }
        
        let mimeData = MimeBuilder.buildReply(
            to: recipients,
            from: fromEmail,
            body: body,
            subject: subject,
            inReplyTo: inReplyTo,
            references: references
        )
        
        return try await sendMessage(mimeData: mimeData, threadId: threadId)
    }
    
    private func sendMessage(mimeData: Data, threadId: String?) async throws -> SendResult {
        let rawMessage = MimeBuilder.base64UrlEncode(mimeData)
        
        var requestBody: [String: Any] = ["raw": rawMessage]
        if let threadId = threadId {
            requestBody["threadId"] = threadId
        }
        
        let accessToken = try await authSession.withFreshToken()
        
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send") else {
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
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw SendError.apiError("Failed to send message: \(errorMessage)")
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageId = json["id"] as? String,
                  let returnedThreadId = json["threadId"] as? String else {
                throw SendError.apiError("Invalid response format")
            }
        
        return SendResult(messageId: messageId, threadId: returnedThreadId)
    }
    
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        threadId: String? = nil
    ) -> Message {
        var optimisticMessage: Message!
        
        viewContext.performAndWait {
            let message = Message(context: viewContext)
            message.id = UUID().uuidString
            message.isFromMe = true
            message.internalDate = Date()
            message.snippet = String(body.prefix(120))
            message.cleanedSnippet = EmailTextProcessor.createCleanSnippet(from: body)
            message.gmThreadId = threadId ?? ""
            
            // Get account info for myAliases
            let accountRequest = Account.fetchRequest()
            accountRequest.fetchLimit = 1
            guard let account = try? viewContext.fetch(accountRequest).first else {
                // Fallback: create conversation with recipients only
                let conversation = findOrCreateConversation(recipients: recipients, myAliases: [])
                message.conversation = conversation
                optimisticMessage = message
                return
            }
            
            let myAliases = Set(([account.email] + account.aliasesArray).map(normalizedEmail))
            let conversation = findOrCreateConversation(recipients: recipients, myAliases: myAliases)
            message.conversation = conversation
            
            // Update conversation to bump it to the top
            conversation.lastMessageDate = Date()
            conversation.snippet = message.cleanedSnippet ?? message.snippet
            // IMPORTANT: do NOT set conversation.hasInbox = true here for outgoing messages
            
            do {
                if viewContext.hasChanges {
                    try viewContext.save()
                }
            } catch {
                print("Failed to save optimistic message: \(error)")
            }
            
            optimisticMessage = message
        }
        
        return optimisticMessage
    }
    
    func updateOptimisticMessage(_ message: Message, with result: SendResult) {
        viewContext.performAndWait {
            message.id = result.messageId
            message.gmThreadId = result.threadId
            
            do {
                if viewContext.hasChanges {
                    try viewContext.save()
                }
            } catch {
                print("Failed to update message with Gmail ID: \(error)")
            }
        }
    }
    
    func deleteOptimisticMessage(_ message: Message) {
        viewContext.performAndWait {
            viewContext.delete(message)
            
            do {
                if viewContext.hasChanges {
                    try viewContext.save()
                }
            } catch {
                print("Failed to delete optimistic message: \(error)")
            }
        }
    }
    
    private func findOrCreateConversation(recipients: [String], myAliases: Set<String>) -> Conversation {
        // Build minimal headers for identity: From + To
        let identityHeaders = recipients.map { MessageHeader(name: "To", value: $0) }
        let identity = makeConversationIdentity(from: identityHeaders, myAliases: myAliases)
        
        let request: NSFetchRequest<Conversation> = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "keyHash == %@", identity.keyHash)
        request.fetchLimit = 1
        
        if let existing = try? viewContext.fetch(request).first {
            return existing
        }
        
        let conversation = Conversation(context: viewContext)
        conversation.id = UUID()
        conversation.keyHash = identity.keyHash
        conversation.conversationType = identity.type
        conversation.lastMessageDate = Date()
        conversation.inboxUnreadCount = 0
        conversation.hasInbox = false  // IMPORTANT: do NOT set to true for outgoing messages
        conversation.hidden = false
        conversation.displayName = recipients.joined(separator: ", ")
        
        // Create participants
        for email in identity.participants {
            let personRequest = Person.fetchRequest()
            personRequest.predicate = NSPredicate(format: "email == %@", email)
            personRequest.fetchLimit = 1
            
            let person: Person
            if let existingPerson = try? viewContext.fetch(personRequest).first {
                person = existingPerson
            } else {
                person = Person(context: viewContext)
                person.id = UUID()
                person.email = email
            }
            
            let participant = ConversationParticipant(context: viewContext)
            participant.id = UUID()
            participant.participantRole = .normal
            participant.person = person
            participant.conversation = conversation
        }
        
        return conversation
    }
}