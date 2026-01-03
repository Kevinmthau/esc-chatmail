import Foundation
import CoreData

// MARK: - Core Data Batch Operations

/// Coordinator for batch Core Data operations.
/// Uses chunking, retry logic, and performance monitoring for efficient bulk operations.
///
/// The implementation is split across multiple files:
/// - `CoreData/BatchOperations/BatchConfiguration.swift`: Error enum, config, ProcessedConversation
/// - `CoreData/BatchOperations/MessageBatchOperations.swift`: Message insert/update/delete
/// - `CoreData/BatchOperations/ConversationBatchOperations.swift`: Conversation insert
struct CoreDataBatchOperations: Sendable {

    // MARK: - Dependencies (internal for extensions)

    let coreDataStack: CoreDataStack
    let performanceMonitor = PerformanceMonitor()

    // MARK: - Initialization

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Context Save with Retry

    /// Saves the context with retry logic for transient errors.
    /// - Parameters:
    ///   - context: The managed object context to save
    ///   - maxRetries: Maximum number of retry attempts
    func saveContextWithRetry(_ context: NSManagedObjectContext, maxRetries: Int = 3) throws {
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
                        Log.warning("Validation errors: \(nsError.userInfo)", category: .coreData)
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

    // MARK: - Mapping Functions

    /// Maps a ProcessedMessage to a managed Message entity.
    func mapProcessedToManagedMessage(_ processed: ProcessedMessage, to managed: Message) {
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

    /// Maps a ProcessedConversation to a managed Conversation entity.
    func mapProcessedToManagedConversation(_ processed: ProcessedConversation, to managed: Conversation) {
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

// Array extension for chunking is already defined in SyncEngine.swift
// AttachmentInfo is already defined in MessageProcessor.swift
