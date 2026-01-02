import Foundation

/// Represents a queued fetch operation
struct FetchTask: Identifiable, Sendable {
    let id = UUID()
    let messageIds: [String]
    let priority: FetchPriority
    let completion: @Sendable ([GmailMessage]) -> Void
}
