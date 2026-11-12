import Foundation
@testable import esc_chatmail

/// An address book that knows nobody, so names come from the stored `Person`
/// rows and message headers alone and the real Contacts store is never asked.
struct NobodyContactsResolver: ContactsResolving {
    func ensureAuthorization() async throws {}
    func lookup(email: String) async -> ContactMatch? { nil }
    func prewarm(emails: [String]) async {}
}
