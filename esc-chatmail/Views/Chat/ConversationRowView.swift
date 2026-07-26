import SwiftUI
import CoreData
import Combine

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
    let participantEmails: [String]
    let participantDisplayNameFingerprint: String
    let showsGroupAvatar: Bool
    let conversationType: ConversationType

    init(from conversation: Conversation) {
        let conversationType = conversation.conversationType
        self.objectID = conversation.objectID
        self.inboxUnreadCount = conversation.inboxUnreadCount
        self.pinned = conversation.pinned
        self.snippet = conversation.snippet
        self.lastMessageDate = conversation.lastMessageDate
        self.displayNameHint = conversation.displayName
        self.participantHash = conversation.participantHash
        self.participantEmails = conversationType == .list
            ? []
            : Self.participantEmails(from: conversation)
        self.participantDisplayNameFingerprint = conversationType == .list
            ? ""
            : Self.participantDisplayNameFingerprint(from: conversation)
        self.showsGroupAvatar = conversationType != .oneToOne
        self.conversationType = conversationType
    }

    private static func participantEmails(from conversation: Conversation) -> [String] {
        let emails = conversation.participants?
            .compactMap { participant -> String? in
                guard let person = participant.person else { return nil }
                guard !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) else { return nil }
                let normalizedEmail = EmailNormalizer.normalize(person.email)
                return normalizedEmail.isEmpty ? nil : normalizedEmail
            } ?? []

        return Array(Set(emails)).sorted()
    }

    private static func participantDisplayNameFingerprint(from conversation: Conversation) -> String {
        let entries = conversation.participants?
            .compactMap { participant -> String? in
                guard let person = participant.person else { return nil }
                let normalizedEmail = EmailNormalizer.normalize(person.email)
                guard !normalizedEmail.isEmpty else { return nil }
                return "\(normalizedEmail)=\(person.displayName ?? "")"
            } ?? []

        return Array(Set(entries)).sorted().joined(separator: "|")
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
    @State private var participantRefreshToken = 0

    @MainActor
    init(
        snapshot: ConversationSnapshot,
        conversationObjectID: NSManagedObjectID,
        conversationContext: NSManagedObjectContext,
        currentUserEmail: String,
        participantLoader: ParticipantLoader
    ) {
        self.snapshot = snapshot
        self.currentUserEmail = currentUserEmail
        self.participantLoader = participantLoader
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
                alignedAvatarPhotos: avatarPhotos,
                participants: participantNames,
                showsGroupAvatar: showsGroupAvatar,
                fallbackDisplayText: fallbackDisplayName
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
            .onReceive(NotificationCenter.default.publisher(for: .personDisplayInfoDidChange).receive(on: DispatchQueue.main)) { notification in
                refreshParticipantInfoIfNeeded(for: notification)
            }
        } else {
            rowContent
                .onReceive(NotificationCenter.default.publisher(for: .personDisplayInfoDidChange).receive(on: DispatchQueue.main)) { notification in
                    refreshParticipantInfoIfNeeded(for: notification)
                }
        }
    }

    private var participantInfoKey: String {
        [
            conversationObjectID.uriRepresentation().absoluteString,
            snapshot.participantHash ?? "",
            snapshot.displayNameHint ?? "",
            snapshot.participantDisplayNameFingerprint,
            EmailNormalizer.normalize(currentUserEmail),
            String(participantRefreshToken)
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
        guard Self.shouldLoadParticipantInfo(
            conversationType: snapshot.conversationType
        ) else {
            return nil
        }

        return Self.resolvedParticipantInfo(
            cachedFull: cachedFullParticipantInfo,
            cachedBase: cachedBaseParticipantInfo,
            uncached: currentUncachedParticipantInfo
        )
    }

    private var currentUncachedParticipantInfo: ParticipantLoader.ParticipantInfo? {
        guard uncachedParticipantInfoKey == participantInfoKey else {
            return nil
        }

        return uncachedParticipantInfo
    }

    private var displayName: String {
        Self.resolvedDisplayName(
            conversationType: snapshot.conversationType,
            storedDisplayName: fallbackDisplayName,
            participantInfo: effectiveParticipantInfo
        )
    }

    private var participantNames: [String] {
        Self.resolvedAvatarDisplayNames(
            conversationType: snapshot.conversationType,
            participantInfo: effectiveParticipantInfo
        )
    }

    private var avatarPhotos: [ProfilePhoto?] {
        Self.resolvedAvatarPhotos(
            conversationType: snapshot.conversationType,
            participantInfo: effectiveParticipantInfo
        )
    }

    private var showsGroupAvatar: Bool {
        Self.resolvedShowsGroupAvatar(
            snapshotShowsGroupAvatar: snapshot.showsGroupAvatar,
            conversationType: snapshot.conversationType,
            participantInfo: effectiveParticipantInfo
        )
    }

    private var fallbackDisplayName: String {
        PersonDisplayNameResolver.displayFallbackConversationName(
            hint: snapshot.displayNameHint,
            participantEmails: nonSelfParticipantEmails
        )
    }

    private var nonSelfParticipantEmails: [String] {
        let normalizedCurrentUserEmail = EmailNormalizer.normalize(currentUserEmail)
        return snapshot.participantEmails.filter { email in
            EmailNormalizer.normalize(email) != normalizedCurrentUserEmail
        }
    }

    private var needsParticipantLoad: Bool {
        guard Self.shouldLoadParticipantInfo(
            conversationType: snapshot.conversationType
        ) else {
            return false
        }

        if snapshot.participantHash?.isEmpty == false {
            return cachedFullParticipantInfo == nil
        }

        return currentUncachedParticipantInfo == nil
    }

    static func resolvedParticipantInfo(
        cachedFull: ParticipantLoader.ParticipantInfo?,
        cachedBase: ParticipantLoader.ParticipantInfo?,
        uncached: ParticipantLoader.ParticipantInfo?
    ) -> ParticipantLoader.ParticipantInfo? {
        if let cachedFull {
            return cachedFull
        }

        guard let cachedBase else {
            return uncached
        }

        guard let uncached, !uncached.photos.isEmpty else {
            return cachedBase
        }

        return ParticipantLoader.ParticipantInfo(
            emails: cachedBase.emails,
            displayNames: cachedBase.displayNames,
            photos: uncached.photos,
            formattedDisplayName: cachedBase.formattedDisplayName,
            totalUniqueParticipants: cachedBase.totalUniqueParticipants,
            avatarDisplayNames: cachedBase.avatarDisplayNames,
            avatarPhotos: uncached.avatarPhotos
        )
    }

    static func resolvedShowsGroupAvatar(
        snapshotShowsGroupAvatar: Bool,
        conversationType: ConversationType,
        participantInfo: ParticipantLoader.ParticipantInfo?
    ) -> Bool {
        if conversationType == .list {
            return true
        }

        if let participantInfo {
            return participantInfo.totalUniqueParticipants > 1
        }

        return snapshotShowsGroupAvatar
    }

    static func shouldLoadParticipantInfo(
        conversationType: ConversationType
    ) -> Bool {
        conversationType != .list
    }

    static func resolvedAvatarDisplayNames(
        conversationType: ConversationType,
        participantInfo: ParticipantLoader.ParticipantInfo?
    ) -> [String] {
        guard shouldLoadParticipantInfo(conversationType: conversationType) else {
            return []
        }
        return participantInfo?.avatarDisplayNames ?? []
    }

    static func resolvedAvatarPhotos(
        conversationType: ConversationType,
        participantInfo: ParticipantLoader.ParticipantInfo?
    ) -> [ProfilePhoto?] {
        guard shouldLoadParticipantInfo(conversationType: conversationType) else {
            return []
        }
        return participantInfo?.avatarPhotos ?? []
    }

    static func resolvedDisplayName(
        conversationType: ConversationType,
        storedDisplayName: String,
        participantInfo: ParticipantLoader.ParticipantInfo?
    ) -> String {
        if conversationType == .list {
            return storedDisplayName
        }

        return participantInfo?.formattedDisplayName ?? storedDisplayName
    }

    private func loadContactInfo(for participantInfoKey: String) async {
        guard Self.shouldLoadParticipantInfo(
            conversationType: snapshot.conversationType
        ) else {
            return
        }

        let info = await participantLoader.loadParticipants(
            from: conversationObjectID,
            in: conversationContext,
            currentUserEmail: currentUserEmail,
            maxParticipants: 4,
            participantHash: snapshot.participantHash,
            fallbackDisplayName: snapshot.displayNameHint
        )

        guard participantInfoKey == self.participantInfoKey else { return }

        uncachedParticipantInfo = info
        uncachedParticipantInfoKey = participantInfoKey
    }

    private func refreshParticipantInfoIfNeeded(for notification: Notification) {
        guard Self.shouldLoadParticipantInfo(
            conversationType: snapshot.conversationType
        ) else {
            return
        }

        let changedEmails = PersonDisplayInfoChangeNotification.emails(from: notification)
        guard changedEmails.isEmpty || !Set(snapshot.participantEmails).isDisjoint(with: changedEmails) else {
            return
        }

        uncachedParticipantInfo = nil
        uncachedParticipantInfoKey = nil
        participantRefreshToken &+= 1
    }

    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
