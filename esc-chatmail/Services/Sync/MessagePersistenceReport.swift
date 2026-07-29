import Foundation

/// Per-ID disposition of one persistence attempt.
enum MessagePersistDisposition: Sendable, Equatable {
    /// The message row was created or updated in the context.
    case persisted
    /// Deliberately not stored (excluded mailbox); any local row was removed.
    case excluded
    /// The payload is malformed in a way that repeats on every fetch (missing
    /// payload/headers), so retrying cannot succeed. Non-blocking for the
    /// cursor — treating it as a failure would livelock sync forever.
    case unprocessable
    /// Persistence failed for a reason that may succeed later. The cursor
    /// must not advance past this ID.
    case failed
}

/// Aggregate outcome of persisting a batch of fetched messages: every
/// attempted ID lands in exactly one bucket. This is the persistence half of
/// the sync invariant — a requested Gmail ID may only be left behind by an
/// advancing cursor when it is persisted, deliberately excluded, gone from
/// the server, or deterministically unprocessable.
struct MessagePersistenceReport: Sendable {
    private(set) var persistedIds: [String] = []
    private(set) var excludedIds: [String] = []
    private(set) var unprocessableIds: [String] = []
    private(set) var failedIds: [String] = []

    static let empty = MessagePersistenceReport()

    mutating func record(_ id: String, _ disposition: MessagePersistDisposition) {
        switch disposition {
        case .persisted: persistedIds.append(id)
        case .excluded: excludedIds.append(id)
        case .unprocessable: unprocessableIds.append(id)
        case .failed: failedIds.append(id)
        }
    }

    mutating func merge(_ other: MessagePersistenceReport) {
        persistedIds.append(contentsOf: other.persistedIds)
        excludedIds.append(contentsOf: other.excludedIds)
        unprocessableIds.append(contentsOf: other.unprocessableIds)
        failedIds.append(contentsOf: other.failedIds)
    }
}
