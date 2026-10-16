import Foundation
import CoreData

/// Centralizes conversation reuse and archive reactivation rules.
///
/// The app supports multiple conversation epochs with the same participant hash,
/// so participant-hash fallback should not blindly reuse archived conversations.
struct ConversationRoutingPolicy: Sendable {
    func shouldReactivateArchivedConversation(
        labelIDs: some Collection<String>,
        isFromMe: Bool
    ) -> Bool {
        let labelSet = Set(labelIDs)
        return labelSet.contains("INBOX") || isFromMe || labelSet.contains("SENT")
    }

    func selectParticipantHashConversation(
        from conversations: [Conversation],
        reactivateArchivedIfNeeded: Bool
    ) -> Conversation? {
        if let activeConversation = conversations
            .filter({ $0.archivedAt == nil })
            .max(by: isLessRecentConversation) {
            return activeConversation
        }

        guard reactivateArchivedIfNeeded else { return nil }

        return conversations.max(by: isLessRecentConversation)
    }

    func reactivateArchivedConversationIfNeeded(
        _ conversation: Conversation,
        shouldReactivate: Bool
    ) {
        guard shouldReactivate, conversation.archivedAt != nil || conversation.hidden else { return }
        // Guard each field on its own: a conversation that is archived but not
        // hidden (or the reverse) would otherwise take an equal-value write on
        // the other field, which Core Data still records as an update.
        if conversation.archivedAt != nil {
            conversation.archivedAt = nil
        }
        if conversation.hidden {
            conversation.hidden = false
        }
    }

    /// Every write here is skipped when the value is unchanged. Core Data
    /// marks a row updated on an equal-value assignment, and this runs after
    /// every rollup, so an unguarded `archivedAt = nil; hidden = false` kept
    /// every inbox conversation dirty on every run even once the rollup
    /// itself wrote nothing.
    func applyArchiveState(
        to conversation: Conversation,
        snapshot: ConversationRollupSnapshot
    ) {
        if snapshot.hasInbox {
            if conversation.archivedAt != nil {
                conversation.archivedAt = nil
            }
            if conversation.hidden {
                conversation.hidden = false
            }
            return
        }

        if snapshot.isSentOnlyConversation {
            if conversation.archivedAt == nil, conversation.hidden {
                conversation.hidden = false
            }
            return
        }

        if snapshot.latestVisibleMessageIsOutgoing {
            if conversation.archivedAt == nil, conversation.hidden {
                conversation.hidden = false
            }
            return
        }

        if conversation.archivedAt == nil {
            conversation.archivedAt = Date()
        }
        if !conversation.hidden {
            conversation.hidden = true
        }
    }

    private func isLessRecentConversation(_ lhs: Conversation, than rhs: Conversation) -> Bool {
        conversationRecencyDate(lhs) < conversationRecencyDate(rhs)
    }

    private func conversationRecencyDate(_ conversation: Conversation) -> Date {
        conversation.lastMessageDate ?? conversation.latestInboxDate ?? conversation.archivedAt ?? .distantPast
    }
}
