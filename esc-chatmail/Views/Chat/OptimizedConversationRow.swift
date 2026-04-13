import SwiftUI
import CoreData

// MARK: - Optimized Conversation Row
struct OptimizedConversationRow: View {
    let snapshot: ConversationSnapshot
    let onAppear: () -> Void

    private let authSession = AuthSession.shared
    private let participantLoader = ParticipantLoader.shared
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext?
    private let fallbackDisplayName: String?

    @State private var displayName: String = ""
    @State private var avatarPhotos: [ProfilePhoto] = []
    @State private var participantNames: [String] = []

    @MainActor
    init(conversation: Conversation, onAppear: @escaping () -> Void) {
        self.snapshot = ConversationSnapshot(from: conversation)
        self.onAppear = onAppear
        self.conversationObjectID = conversation.objectID
        self.conversationContext = conversation.managedObjectContext
        self.fallbackDisplayName = snapshot.displayNameHint
        self._displayName = State(initialValue: snapshot.displayNameHint ?? "")
    }

    private var timeString: String {
        guard let date = snapshot.lastMessageDate else { return "" }
        return TimestampFormatter.format(date)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Avatar stack with photo support
            AvatarStackView(
                avatarPhotos: avatarPhotos,
                participants: participantNames,
                fallbackDisplayText: fallbackDisplayName
            )
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack {
                    Text(displayName.isEmpty ? (snapshot.displayNameHint ?? "Unknown") : displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Text(timeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Snippet
                Text(snapshot.snippet ?? "")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Indicators
                HStack(spacing: 8) {
                    if snapshot.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if snapshot.inboxUnreadCount > 0 {
                        UnreadBadge(count: Int(snapshot.inboxUnreadCount))
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 16)
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
        guard let conversationContext else { return }

        let info = await participantLoader.loadParticipants(
            from: conversationObjectID,
            in: conversationContext,
            currentUserEmail: myEmail,
            maxParticipants: 4,
            fallbackDisplayName: fallbackDisplayName
        )

        displayName = info.formattedDisplayName
        participantNames = info.displayNames
        avatarPhotos = info.photos
    }
}
