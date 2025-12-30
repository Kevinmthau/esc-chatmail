import SwiftUI

// MARK: - Optimized Conversation Row
struct OptimizedConversationRow: View {
    @ObservedObject var conversation: Conversation
    let onAppear: () -> Void

    private var participantNames: String {
        guard let participantsSet = conversation.participants as? NSSet else {
            return "Unknown"
        }

        let names = participantsSet
            .compactMap { ($0 as? ConversationParticipant)?.person?.displayName ?? ($0 as? ConversationParticipant)?.person?.email }
            .prefix(3)
            .joined(separator: ", ")

        return names.isEmpty ? "No participants" : names
    }

    private var timeString: String {
        guard let date = conversation.lastMessageDate else { return "" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AvatarView(name: participantNames)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack {
                    Text(conversation.displayName ?? participantNames)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Text(timeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Snippet
                Text(conversation.snippet ?? "")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Indicators
                HStack(spacing: 8) {
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if conversation.inboxUnreadCount > 0 {
                        UnreadBadge(count: Int(conversation.inboxUnreadCount))
                    }

                    if conversation.hasInbox {
                        Image(systemName: "tray.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 20)
        .background(Color(.systemBackground))
        .onAppear {
            onAppear()
        }
    }
}
