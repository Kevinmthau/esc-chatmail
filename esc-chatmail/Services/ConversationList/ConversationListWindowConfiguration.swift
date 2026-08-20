import Foundation

/// Sizing knobs for the conversation list's paged Core Data window.
///
/// `ConversationWindowProvider` previously borrowed `VirtualScrollConfiguration`
/// — the chat *message* window's scrolling config — and derived these values
/// from it, so retuning the message page size silently retuned the list's page
/// size and initial window. The list's knobs live here so each surface can be
/// tuned independently.
struct ConversationListWindowConfiguration {
    /// Row count of the first fetched window, before any paging.
    let initialLimit: Int
    /// Rows added to the window per `loadMoreIfNeeded` page.
    let pageSize: Int
    /// How many trailing rows arm the next page: appearance of any of the
    /// window's last `preloadThreshold` rows triggers a load.
    let preloadThreshold: Int
    /// Over-fetch factor for filters that must scan past invisible rows
    /// (contacts/other): each candidate batch fetches up to
    /// `limit * contactFilterCandidateMultiplier` persisted rows.
    let contactFilterCandidateMultiplier: Int

    /// Production numbers, identical to what the provider formerly derived
    /// from `VirtualScrollConfiguration.default` (pageSize 50, preloadThreshold
    /// 5): `initialLimit = pageSize * 2`, multiplier hard-coded at 5. Hard-coded
    /// here so retuning the chat message window no longer retunes the list.
    static let `default` = ConversationListWindowConfiguration(
        initialLimit: 100,
        pageSize: 50,
        preloadThreshold: 5,
        contactFilterCandidateMultiplier: 5
    )
}
