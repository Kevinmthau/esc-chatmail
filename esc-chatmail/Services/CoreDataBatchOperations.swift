import Foundation
import CoreData

// MARK: - Batch Operation Error
enum BatchOperationError: LocalizedError {
    case invalidBatchSize
    case contextSaveFailure(Error)
    case batchInsertFailure(Error)
    case batchUpdateFailure(Error)

    var errorDescription: String? {
        switch self {
        case .invalidBatchSize:
            return "Invalid batch size specified"
        case .contextSaveFailure(let error):
            return "Failed to save context: \(error.localizedDescription)"
        case .batchInsertFailure(let error):
            return "Batch insert failed: \(error.localizedDescription)"
        case .batchUpdateFailure(let error):
            return "Batch update failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Batch Operation Configuration
struct BatchConfiguration {
    let batchSize: Int
    let saveInterval: Int
    let useBatchInsert: Bool
    let useBackgroundQueue: Bool

    static let `default` = BatchConfiguration(
        batchSize: 100,
        saveInterval: 500,
        useBatchInsert: true,
        useBackgroundQueue: true
    )

    static let lightweight = BatchConfiguration(
        batchSize: 50,
        saveInterval: 200,
        useBatchInsert: true,
        useBackgroundQueue: true
    )

    static let heavy = BatchConfiguration(
        batchSize: 200,
        saveInterval: 1000,
        useBatchInsert: true,
        useBackgroundQueue: true
    )
}

// MARK: - Core Data Batch Operations
final class CoreDataBatchOperations: @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    private let performanceMonitor = PerformanceMonitor()

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Batch Insert for Messages
    func batchInsertMessages(_ messages: [ProcessedMessage], configuration: BatchConfiguration = .default) async throws {
        guard !messages.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        // Configure context for batch operations
        context.undoManager = nil
        context.shouldDeleteInaccessibleFaults = true
        context.automaticallyMergesChangesFromParent = false

        // Track performance
        let startTime = Date()
        var insertedCount = 0

        try await context.perform {
            // Process in chunks to avoid memory issues
            for chunk in messages.chunked(into: configuration.batchSize) {
                // Check for existing messages to avoid duplicates
                let messageIds = chunk.map { $0.id }
                let existingRequest = NSFetchRequest<Message>(entityName: "Message")
                existingRequest.predicate = NSPredicate(format: "id IN %@", messageIds)
                existingRequest.resultType = .dictionaryResultType
                existingRequest.propertiesToFetch = ["id"]

                let existingResults = try context.fetch(existingRequest) as? [[String: String]] ?? []
                let existingIds = Set(existingResults.compactMap { $0["id"] })

                // Insert only new messages
                for processedMessage in chunk where !existingIds.contains(processedMessage.id) {
                    let message = Message(context: context)
                    self.mapProcessedToManagedMessage(processedMessage, to: message)
                    insertedCount += 1
                }

                // Save at intervals to prevent memory buildup
                if insertedCount % configuration.saveInterval == 0 {
                    try self.saveContextWithRetry(context)
                    context.reset() // Clear memory after save
                }
            }

            // Final save for remaining messages
            if context.hasChanges {
                try self.saveContextWithRetry(context)
            }
        }

        // Log performance metrics
        let duration = Date().timeIntervalSince(startTime)
        performanceMonitor.log(operation: "batchInsertMessages",
                              count: insertedCount,
                              duration: duration)

        print("Batch inserted \(insertedCount) messages in \(String(format: "%.2f", duration))s")
    }

    // MARK: - Batch Update for Messages
    func batchUpdateMessages(with updates: [(id: String, changes: [String: Any])], configuration: BatchConfiguration = .default) async throws {
        guard !updates.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        context.undoManager = nil
        context.automaticallyMergesChangesFromParent = false

        var updatedCount = 0

        try await context.perform {
            for chunk in updates.chunked(into: configuration.batchSize) {
                // Fetch messages to update
                let messageIds = chunk.map { $0.id }
                let request = NSFetchRequest<Message>(entityName: "Message")
                request.predicate = NSPredicate(format: "id IN %@", messageIds)
                request.returnsObjectsAsFaults = false

                let messages = try context.fetch(request)
                let messageDict = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

                // Apply updates
                for (id, changes) in chunk {
                    guard let message = messageDict[id] else { continue }

                    for (key, value) in changes {
                        message.setValue(value, forKey: key)
                    }
                    updatedCount += 1
                }

                // Save at intervals
                if updatedCount % configuration.saveInterval == 0 {
                    try self.saveContextWithRetry(context)
                }
            }

            // Final save
            if context.hasChanges {
                try self.saveContextWithRetry(context)
            }
        }

        print("Batch updated \(updatedCount) messages")
    }

    // MARK: - Batch Delete for Messages
    func batchDeleteMessages(withIds messageIds: [String], configuration: BatchConfiguration = .default) async throws {
        guard !messageIds.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        try await context.perform {
            // Use NSBatchDeleteRequest for efficiency
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = NSPredicate(format: "id IN %@", messageIds)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

            // Configure to merge changes
            deleteRequest.resultType = .resultTypeObjectIDs

            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            guard let objectIDs = result?.result as? [NSManagedObjectID] else { return }

            // Merge changes to other contexts
            let changes = [NSDeletedObjectsKey: objectIDs]
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: changes,
                into: [self.coreDataStack.viewContext]
            )
        }

        print("Batch deleted \(messageIds.count) messages")
    }

    // MARK: - Batch Insert for Conversations
    func batchInsertConversations(_ conversations: [ProcessedConversation], configuration: BatchConfiguration = .default) async throws {
        guard !conversations.isEmpty else { return }

        let context = configuration.useBackgroundQueue ?
            coreDataStack.newBackgroundContext() :
            coreDataStack.viewContext

        context.undoManager = nil
        context.automaticallyMergesChangesFromParent = false

        var insertedCount = 0

        try await context.perform {
            for chunk in conversations.chunked(into: configuration.batchSize) {
                // Check existing conversations
                let keyHashes = chunk.map { $0.keyHash }
                let existingRequest = NSFetchRequest<Conversation>(entityName: "Conversation")
                existingRequest.predicate = NSPredicate(format: "keyHash IN %@", keyHashes)
                existingRequest.resultType = .dictionaryResultType
                existingRequest.propertiesToFetch = ["keyHash"]

                let existingResults = try context.fetch(existingRequest) as? [[String: String]] ?? []
                let existingHashes = Set(existingResults.compactMap { $0["keyHash"] })

                // Insert only new conversations
                for processedConv in chunk where !existingHashes.contains(processedConv.keyHash) {
                    let conversation = Conversation(context: context)
                    self.mapProcessedToManagedConversation(processedConv, to: conversation)
                    insertedCount += 1
                }

                // Save at intervals
                if insertedCount % configuration.saveInterval == 0 {
                    try self.saveContextWithRetry(context)
                    context.reset()
                }
            }

            // Final save
            if context.hasChanges {
                try self.saveContextWithRetry(context)
            }
        }

        print("Batch inserted \(insertedCount) conversations")
    }

    // MARK: - Helper Methods

    private func saveContextWithRetry(_ context: NSManagedObjectContext, maxRetries: Int = 3) throws {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try context.save()
                return
            } catch {
                lastError = error

                // Handle specific Core Data errors
                if let nsError = error as NSError? {
                    // Check for constraint violations
                    if nsError.code == NSManagedObjectConstraintMergeError {
                        // Resolve conflicts by keeping the store version
                        context.rollback()
                        return
                    }

                    // Check for validation errors
                    if nsError.code == NSValidationMultipleErrorsError {
                        print("Validation errors: \(nsError.userInfo)")
                        throw BatchOperationError.contextSaveFailure(error)
                    }
                }

                // Retry with exponential backoff
                if attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt - 1)) * 0.1
                    Thread.sleep(forTimeInterval: delay)
                }
            }
        }

        throw BatchOperationError.contextSaveFailure(lastError ?? NSError())
    }

    private func mapProcessedToManagedMessage(_ processed: ProcessedMessage, to managed: Message) {
        managed.setValue(processed.id, forKey: "id")
        managed.setValue(processed.gmThreadId, forKey: "gmThreadId")
        managed.setValue(processed.snippet, forKey: "snippet")
        managed.setValue(processed.cleanedSnippet, forKey: "cleanedSnippet")
        managed.setValue(processed.internalDate, forKey: "internalDate")
        managed.setValue(processed.isUnread, forKey: "isUnread")
        managed.setValue(processed.hasAttachments, forKey: "hasAttachments")
        managed.setValue(processed.headers.isFromMe, forKey: "isFromMe")
        managed.setValue(processed.headers.subject, forKey: "subject")
        managed.setValue(processed.headers.messageId, forKey: "messageId")
        managed.setValue(processed.headers.references.isEmpty ? nil : processed.headers.references.joined(separator: " "), forKey: "references")

        // Store body content efficiently
        if let html = processed.htmlBody {
            managed.setValue(html, forKey: "bodyText")
            managed.setValue(nil, forKey: "bodyStorageURI")
        } else if let plain = processed.plainTextBody {
            managed.setValue(plain, forKey: "bodyText")
            managed.setValue(nil, forKey: "bodyStorageURI")
        }

        // Extract sender info
        if let from = processed.headers.from {
            let email = EmailNormalizer.extractEmail(from: from)
            let displayName = EmailNormalizer.extractDisplayName(from: from)
            managed.setValue(email, forKey: "senderEmail")
            managed.setValue(displayName, forKey: "senderName")
        }
    }

    private func mapProcessedToManagedConversation(_ processed: ProcessedConversation, to managed: Conversation) {
        managed.setValue(processed.id, forKey: "id")
        managed.setValue(processed.keyHash, forKey: "keyHash")
        managed.setValue(processed.type, forKey: "type")
        managed.setValue(processed.displayName, forKey: "displayName")
        managed.setValue(processed.snippet, forKey: "snippet")
        managed.setValue(processed.lastMessageDate, forKey: "lastMessageDate")
        managed.setValue(Int32(processed.inboxUnreadCount), forKey: "inboxUnreadCount")
        managed.setValue(processed.hasInbox, forKey: "hasInbox")
        managed.setValue(processed.latestInboxDate, forKey: "latestInboxDate")
    }
}

// MARK: - Performance Monitor
private final class PerformanceMonitor: Sendable {
    func log(operation: String, count: Int, duration: TimeInterval) {
        let throughput = Double(count) / duration
        print("📊 Performance: \(operation) - \(count) items in \(String(format: "%.2f", duration))s (\(String(format: "%.0f", throughput)) items/sec)")
    }
}

// Array extension for chunking is already defined in SyncEngine.swift

// MARK: - Processed Data Models
// Note: ProcessedMessage is defined in MessageProcessor.swift
// We extend it here for batch operations compatibility

struct ProcessedConversation {
    let id: UUID
    let keyHash: String
    let type: String
    let displayName: String?
    let snippet: String?
    let lastMessageDate: Date?
    let inboxUnreadCount: Int
    let hasInbox: Bool
    let latestInboxDate: Date?
}

// AttachmentInfo is already defined in MessageProcessor.swift