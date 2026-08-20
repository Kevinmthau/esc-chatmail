import Foundation

/// Decision logic for the chat list's person/avatar prefetching (F19).
///
/// Pure static functions, per house style for view/view-model decisions, so
/// the dedup/exclusion/cap rules stay unit-testable without Core Data or a
/// view model.
enum ConversationListPrefetchPolicy {
    /// Returns the participant emails to submit to the person/avatar
    /// prefetchers for rows newly entering the window: drawn from `newItems`
    /// in window order, de-duplicated (first occurrence wins), excluding
    /// emails in `alreadySubmitted`, and capped at `limit`.
    static func emailsToPrefetch(
        newItems: [ConversationListItem],
        alreadySubmitted: Set<String>,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }

        var seen = alreadySubmitted
        var emails: [String] = []
        for item in newItems {
            for email in item.snapshot.participantEmails where seen.insert(email).inserted {
                emails.append(email)
                if emails.count == limit {
                    return emails
                }
            }
        }
        return emails
    }
}
