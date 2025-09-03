import Foundation
import CoreData

class MessageActions: ObservableObject {
    private let apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    
    func markAsRead(message: Message) async throws {
        message.isUnread = false
        coreDataStack.save(context: coreDataStack.viewContext)
        
        do {
            _ = try await apiClient.modifyMessage(id: message.id, removeLabelIds: ["UNREAD"])
        } catch {
            message.isUnread = true
            coreDataStack.save(context: coreDataStack.viewContext)
            throw error
        }
    }
    
    func markAsUnread(message: Message) async throws {
        message.isUnread = true
        coreDataStack.save(context: coreDataStack.viewContext)
        
        do {
            _ = try await apiClient.modifyMessage(id: message.id, addLabelIds: ["UNREAD"])
        } catch {
            message.isUnread = false
            coreDataStack.save(context: coreDataStack.viewContext)
            throw error
        }
    }
    
    func archive(message: Message) async throws {
        if let labels = message.labels {
            let inboxLabel = labels.first { $0.id == "INBOX" }
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
                coreDataStack.save(context: coreDataStack.viewContext)
                
                do {
                    _ = try await apiClient.modifyMessage(id: message.id, removeLabelIds: ["INBOX"])
                    
                    if let conversation = message.conversation {
                        updateConversationInboxStatus(conversation)
                    }
                } catch {
                    message.addToLabels(inboxLabel)
                    coreDataStack.save(context: coreDataStack.viewContext)
                    throw error
                }
            }
        }
    }
    
    func archiveConversation(conversation: Conversation) async throws {
        guard let messages = conversation.messages else { return }
        
        let inboxMessages = messages.filter { message in
            guard let labels = message.labels else { return false }
            return labels.contains { $0.id == "INBOX" }
        }
        
        let messageIds = inboxMessages.map { $0.id }
        
        if !messageIds.isEmpty {
            let context = coreDataStack.viewContext
            let labelRequest = Label.fetchRequest()
            labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            guard let inboxLabel = try? context.fetch(labelRequest).first else { return }
            
            for message in inboxMessages {
                message.removeFromLabels(inboxLabel)
            }
            coreDataStack.save(context: context)
            
            do {
                try await apiClient.batchModify(ids: messageIds, removeLabelIds: ["INBOX"])
                updateConversationInboxStatus(conversation)
            } catch {
                for message in inboxMessages {
                    message.addToLabels(inboxLabel)
                }
                coreDataStack.save(context: context)
                throw error
            }
        }
    }
    
    func star(message: Message) async throws {
        do {
            _ = try await apiClient.modifyMessage(id: message.id, addLabelIds: ["STARRED"])
        } catch {
            throw error
        }
    }
    
    func unstar(message: Message) async throws {
        do {
            _ = try await apiClient.modifyMessage(id: message.id, removeLabelIds: ["STARRED"])
        } catch {
            throw error
        }
    }
    
    func deleteConversation(conversation: Conversation) async throws {
        guard let messages = conversation.messages else { return }
        
        let messageIds = messages.map { $0.id }
        
        if !messageIds.isEmpty {
            conversation.hidden = true
            coreDataStack.save(context: coreDataStack.viewContext)
            
            do {
                try await apiClient.batchModify(
                    ids: messageIds,
                    addLabelIds: ["TRASH"],
                    removeLabelIds: ["INBOX"]
                )
            } catch {
                conversation.hidden = false
                coreDataStack.save(context: coreDataStack.viewContext)
                throw error
            }
        }
    }
    
    private func updateConversationInboxStatus(_ conversation: Conversation) {
        guard let messages = conversation.messages else { return }
        
        let inboxMessages = messages.filter { message in
            guard let labels = message.labels else { return false }
            return labels.contains { $0.id == "INBOX" }
        }
        
        conversation.hasInbox = !inboxMessages.isEmpty
        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)
        
        if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
            conversation.latestInboxDate = latestInboxMessage.internalDate
        } else {
            conversation.latestInboxDate = nil
        }
        
        coreDataStack.save(context: coreDataStack.viewContext)
    }
}