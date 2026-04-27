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
        conversation.archivedAt = nil
        conversation.hidden = false
    }

    func applyArchiveState(
        to conversation: Conversation,
        snapshot: ConversationRollupSnapshot
    ) {
        if snapshot.hasInbox {
            conversation.archivedAt = nil
            conversation.hidden = false
            return
        }

        if snapshot.isSentOnlyConversation {
            if conversation.archivedAt == nil {
                conversation.hidden = false
            }
            return
        }

        if snapshot.latestVisibleMessageIsOutgoing {
            if conversation.archivedAt == nil {
                conversation.hidden = false
            }
            return
        }

        if conversation.archivedAt == nil {
            conversation.archivedAt = Date()
        }
        conversation.hidden = true
    }

    private func isLessRecentConversation(_ lhs: Conversation, than rhs: Conversation) -> Bool {
        conversationRecencyDate(lhs) < conversationRecencyDate(rhs)
    }

    private func conversationRecencyDate(_ conversation: Conversation) -> Date {
        conversation.lastMessageDate ?? conversation.latestInboxDate ?? conversation.archivedAt ?? .distantPast
    }
}
