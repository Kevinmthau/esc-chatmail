import SwiftUI
import CoreData

/// Snapshot of conversation data to prevent excessive re-renders.
/// Instead of observing the full Conversation object (which triggers re-renders on ANY property change),
/// we capture only the display-relevant properties once and update via explicit refresh.
struct ConversationSnapshot: Equatable {
    let objectID: NSManagedObjectID
    let inboxUnreadCount: Int32
    let pinned: Bool
    let snippet: String?
    let lastMessageDate: Date?
    let displayNameHint: String?

    init(from conversation: Conversation) {
        self.objectID = conversation.objectID
        self.inboxUnreadCount = conversation.inboxUnreadCount
        self.pinned = conversation.pinned
        self.snippet = conversation.snippet
        self.lastMessageDate = conversation.lastMessageDate
        self.displayNameHint = conversation.displayName
    }
}

struct ConversationRowView: View {
    /// Use snapshot to avoid re-renders from unrelated Conversation property changes
    let snapshot: ConversationSnapshot
    /// Keep reference for participant loading (but don't observe it)
    let conversation: Conversation

    private let authSession = AuthSession.shared
    private let participantLoader = ParticipantLoader.shared

    @State private var displayName: String
    @State private var avatarPhotos: [ProfilePhoto] = []
    @State private var participantNames: [String] = []

    init(conversation: Conversation) {
        self.conversation = conversation
        self.snapshot = ConversationSnapshot(from: conversation)
        // Initialize displayName with stored value to prevent flickering
        self._displayName = State(initialValue: conversation.displayName ?? "")
    }

    var body: some View {
        HStack(spacing: 12) {
            // Unread indicator with fixed width container
            ZStack {
                if snapshot.inboxUnreadCount > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 10, height: 10)

            // Avatar stack
            AvatarStackView(avatarPhotos: avatarPhotos, participants: participantNames)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                // Top row: Name, date, and chevron
                HStack {
                    HStack(spacing: 4) {
                        if snapshot.pinned {
                            Image(systemName: "pin.fill")
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }

                        Text(displayName)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        if let date = snapshot.lastMessageDate {
                            Text(formatDate(date))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(.tertiaryLabel))
                    }
                }

                // Bottom row: snippet only
                Text(snapshot.snippet ?? "No messages")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(height: 88)
        .padding(.horizontal, 12)
        .task {
            await loadContactInfo()
        }
    }

    private func loadContactInfo() async {
        let myEmail = authSession.userEmail ?? ""

        // Use ParticipantLoader for all participant resolution
        let info = await participantLoader.loadParticipants(
            from: conversation,
            currentUserEmail: myEmail,
            maxParticipants: 4
        )

        displayName = info.formattedDisplayName
        participantNames = info.displayNames
        avatarPhotos = info.photos
    }

    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
