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
    let participantHash: String?

    init(from conversation: Conversation) {
        self.objectID = conversation.objectID
        self.inboxUnreadCount = conversation.inboxUnreadCount
        self.pinned = conversation.pinned
        self.snippet = conversation.snippet
        self.lastMessageDate = conversation.lastMessageDate
        self.displayNameHint = conversation.displayName
        self.participantHash = conversation.participantHash
    }
}

struct ConversationRowView: View {
    /// Use snapshot to avoid re-renders from unrelated Conversation property changes
    let snapshot: ConversationSnapshot

    private let currentUserEmail: String
    private let participantLoader: ParticipantLoader
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext

    @State private var uncachedParticipantInfo: ParticipantLoader.ParticipantInfo?
    @State private var uncachedParticipantInfoKey: String?
    @State private var cacheRefreshToken = 0

    @MainActor
    init(
        snapshot: ConversationSnapshot,
        conversationObjectID: NSManagedObjectID,
        conversationContext: NSManagedObjectContext,
        deps: Dependencies? = nil
    ) {
        let resolvedDeps = deps ?? Dependencies.shared
        self.snapshot = snapshot
        self.currentUserEmail = resolvedDeps.authSession.userEmail ?? ""
        self.participantLoader = resolvedDeps.participantLoader
        self.conversationObjectID = conversationObjectID
        self.conversationContext = conversationContext
    }

    var body: some View {
        let rowContent = HStack(spacing: 12) {
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
            AvatarStackView(
                avatarPhotos: avatarPhotos,
                participants: participantNames,
                fallbackDisplayText: snapshot.displayNameHint
            )
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

        if needsParticipantLoad {
            rowContent.task(id: participantInfoKey) {
                await loadContactInfo(for: participantInfoKey)
            }
        } else {
            rowContent
        }
    }

    private var participantInfoKey: String {
        [
            conversationObjectID.uriRepresentation().absoluteString,
            snapshot.participantHash ?? "",
            snapshot.displayNameHint ?? "",
            EmailNormalizer.normalize(currentUserEmail)
        ].joined(separator: "|")
    }

    private var cachedBaseParticipantInfo: ParticipantLoader.ParticipantInfo? {
        participantLoader.cachedParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: snapshot.participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: 4,
            fallbackDisplayName: snapshot.displayNameHint,
            includePhotos: false
        )
    }

    private var cachedFullParticipantInfo: ParticipantLoader.ParticipantInfo? {
        participantLoader.cachedParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: snapshot.participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: 4,
            fallbackDisplayName: snapshot.displayNameHint,
            includePhotos: true
        )
    }

    private var effectiveParticipantInfo: ParticipantLoader.ParticipantInfo? {
        cachedFullParticipantInfo
            ?? cachedBaseParticipantInfo
            ?? currentUncachedParticipantInfo
    }

    private var currentUncachedParticipantInfo: ParticipantLoader.ParticipantInfo? {
        guard uncachedParticipantInfoKey == participantInfoKey else {
            return nil
        }

        return uncachedParticipantInfo
    }

    private var displayName: String {
        effectiveParticipantInfo?.formattedDisplayName ?? snapshot.displayNameHint ?? ""
    }

    private var participantNames: [String] {
        effectiveParticipantInfo?.displayNames ?? []
    }

    private var avatarPhotos: [ProfilePhoto] {
        effectiveParticipantInfo?.photos ?? []
    }

    private var needsParticipantLoad: Bool {
        if snapshot.participantHash?.isEmpty == false {
            return cachedFullParticipantInfo == nil
        }

        return currentUncachedParticipantInfo == nil
    }

    private func loadContactInfo(for participantInfoKey: String) async {
        let info = await participantLoader.loadParticipants(
            from: conversationObjectID,
            in: conversationContext,
            currentUserEmail: currentUserEmail,
            maxParticipants: 4,
            participantHash: snapshot.participantHash,
            fallbackDisplayName: snapshot.displayNameHint
        )

        guard participantInfoKey == self.participantInfoKey else { return }

        if snapshot.participantHash?.isEmpty == false {
            uncachedParticipantInfo = nil
            uncachedParticipantInfoKey = nil
            cacheRefreshToken &+= 1
            return
        }

        uncachedParticipantInfo = info
        uncachedParticipantInfoKey = participantInfoKey
    }

    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
