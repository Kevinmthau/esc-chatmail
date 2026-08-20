import Foundation

/// Filter options for the conversation list
enum ConversationFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    case contacts = "Contacts"
    case other = "Other"

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .unread: return "envelope.badge"
        case .contacts: return "person.crop.circle"
        case .other: return "person.crop.circle.badge.questionmark"
        }
    }

    /// Whether evaluating this filter needs the contact-emails cache.
    /// `ConversationFilterService` lazily loads the cache the first time a
    /// filter that requires it becomes current.
    var requiresContactCache: Bool {
        switch self {
        case .contacts, .other:
            return true
        case .all, .unread:
            return false
        }
    }

    /// Whether `ConversationWindowProvider.fetchWindow` must page past
    /// SQL-invisible candidates instead of trusting a plain `fetchLimit`.
    ///
    /// `.contacts`/`.other` cannot be expressed in the store predicate at all
    /// (contact membership lives in the in-memory cache), so every fetched row
    /// is only a candidate. For `.all`/`.unread` the store predicate is exact —
    /// except under search: SQLite `CONTAINS[cd]` and Foundation's
    /// case/diacritic-insensitive matching disagree (e.g. fullwidth "ＪＯＳＥ"),
    /// so the search clause is a deliberate superset candidate filter that is
    /// re-checked in memory, and the scan must page past candidates the
    /// in-memory match rejects.
    func needsInMemoryCandidateScan(hasSearchText: Bool) -> Bool {
        switch self {
        case .all, .unread:
            return hasSearchText
        case .contacts, .other:
            return true
        }
    }

    /// Whether any conversation could match this filter given the current
    /// contact-emails cache state. `.contacts` with an empty cache can match
    /// nothing, so callers skip the candidate scan entirely.
    func canMatchAnything(hasContactEmails: Bool) -> Bool {
        switch self {
        case .all, .unread, .other:
            return true
        case .contacts:
            return hasContactEmails
        }
    }

    /// The per-filter clause `ConversationWindowProvider` appends to its store
    /// predicate, or nil when this filter adds nothing SQL-expressible.
    /// Account-wide clauses (`archivedAt == nil`, the search clause) stay in
    /// the provider — they are not per-filter.
    var storePredicate: NSPredicate? {
        switch self {
        case .unread:
            return NSPredicate(format: "inboxUnreadCount > 0")
        case .all, .contacts, .other:
            return nil
        }
    }
}
