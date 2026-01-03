import Foundation

// MARK: - Batch Operation Error

/// Errors that can occur during batch Core Data operations.
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

// MARK: - Batch Configuration

/// Configuration for batch Core Data operations.
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

// MARK: - Performance Monitor

/// Simple performance logger for batch operations.
final class PerformanceMonitor: Sendable {
    func log(operation: String, count: Int, duration: TimeInterval) {
        let throughput = Double(count) / duration
        Log.debug("Performance: \(operation) - \(count) items in \(String(format: "%.2f", duration))s (\(String(format: "%.0f", throughput)) items/sec)", category: .coreData)
    }
}

// MARK: - Processed Data Models

/// Processed conversation data for batch insertion.
/// Note: ProcessedMessage is defined in MessageProcessor.swift
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
