import SwiftUI

// MARK: - Optimized Conversation Row
struct OptimizedConversationRow: View {
    @ObservedObject var conversation: Conversation
    let onAppear: () -> Void

    private let authSession = AuthSession.shared
    private let participantLoader = ParticipantLoader.shared

    @State private var displayName: String = ""
    @State private var avatarPhotos: [ProfilePhoto] = []
    @State private var participantNames: [String] = []

    private var timeString: String {
        guard let date = conversation.lastMessageDate else { return "" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 16) {
            // Avatar stack with photo support
            AvatarStackView(avatarPhotos: avatarPhotos, participants: participantNames)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack {
                    Text(displayName.isEmpty ? (conversation.displayName ?? "Unknown") : displayName)
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
        .task {
            await loadContactInfo()
        }
    }

    private func loadContactInfo() async {
        let myEmail = authSession.userEmail ?? ""

        let info = await participantLoader.loadParticipants(
            from: conversation,
            currentUserEmail: myEmail,
            maxParticipants: 4
        )

        displayName = info.formattedDisplayName
        participantNames = info.displayNames
        avatarPhotos = info.photos
    }
}
