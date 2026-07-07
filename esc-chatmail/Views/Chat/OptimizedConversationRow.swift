import SwiftUI
import CoreData

// MARK: - Optimized Conversation Row
struct OptimizedConversationRow: View {
    let snapshot: ConversationSnapshot
    let onAppear: () -> Void

    private let currentUserEmail: String
    private let participantLoader: ParticipantLoader
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext?
    private let fallbackDisplayName: String

    @State private var displayName: String = ""
    @State private var avatarPhotos: [ProfilePhoto?] = []
    @State private var participantNames: [String] = []
    @State private var showsGroupAvatar: Bool

    @MainActor
    init(
        conversation: Conversation,
        currentUserEmail: String,
        participantLoader: ParticipantLoader,
        onAppear: @escaping () -> Void
    ) {
        self.snapshot = ConversationSnapshot(from: conversation)
        self.currentUserEmail = currentUserEmail
        self.participantLoader = participantLoader
        self.onAppear = onAppear
        self.conversationObjectID = conversation.objectID
        self.conversationContext = conversation.managedObjectContext
        let nonSelfParticipantEmails = snapshot.participantEmails.filter { email in
            EmailNormalizer.normalize(email) != EmailNormalizer.normalize(currentUserEmail)
        }
        let fallbackDisplayName = PersonDisplayNameResolver.displayFallbackConversationName(
            hint: snapshot.displayNameHint,
            participantEmails: nonSelfParticipantEmails
        )
        self.fallbackDisplayName = fallbackDisplayName
        self._displayName = State(initialValue: fallbackDisplayName)
        self._showsGroupAvatar = State(initialValue: snapshot.showsGroupAvatar)
    }

    private var timeString: String {
        guard let date = snapshot.lastMessageDate else { return "" }
        return TimestampFormatter.format(date)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Avatar stack with photo support
            AvatarStackView(
                alignedAvatarPhotos: avatarPhotos,
                participants: participantNames,
                showsGroupAvatar: showsGroupAvatar,
                fallbackDisplayText: fallbackDisplayName
            )
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack {
                    Text(displayName.isEmpty ? fallbackDisplayName : displayName)
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
        guard let conversationContext else { return }

        let info = await participantLoader.loadParticipants(
            from: conversationObjectID,
            in: conversationContext,
            currentUserEmail: currentUserEmail,
            maxParticipants: 4,
            fallbackDisplayName: fallbackDisplayName
        )

        displayName = info.formattedDisplayName
        participantNames = info.avatarDisplayNames
        avatarPhotos = info.avatarPhotos
        showsGroupAvatar = info.totalUniqueParticipants > 1
    }
}
