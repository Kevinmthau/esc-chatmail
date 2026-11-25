import Foundation
@testable import esc_chatmail

/// A `MockGmailAPIClient.getMessageOperation` that answers the `ok` ID at
/// once and refuses every other ID with a 429 (Retry-After 30) only after
/// the `ok` ID has been asked for, so a test whose fetch pass sends both is
/// not at the mercy of which child task reaches the pacer first: refused
/// first, the pause would keep the `ok` GET from being sent at all.
final class OkSentBeforeLimited: @unchecked Sendable {
    /// Guards `okSent`.
    private let lock = NSLock()
    private var okSent = false

    static func operation(
        ok: (id: String, message: GmailMessage)
    ) -> @Sendable (String, String) async throws -> GmailMessage {
        let gate = OkSentBeforeLimited()
        return { id, _ in
            if id == ok.id {
                gate.lock.withLock { gate.okSent = true }
                return ok.message
            }
            let deadline = Date().addingTimeInterval(5)
            while !gate.lock.withLock({ gate.okSent }), Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw APIError.rateLimited(retryAfter: 30)
        }
    }
}
