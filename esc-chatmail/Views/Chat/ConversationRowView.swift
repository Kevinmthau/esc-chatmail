import SwiftUI
import CoreData
import Combine

struct ConversationRowView: View {
    /// Use snapshot to avoid re-renders from unrelated Conversation property changes
    let snapshot: ConversationSnapshot

    private let currentUserEmail: String
    /// `currentUserEmail` normalized once at init so per-body key builds and
    /// self-participant filtering don't re-run `EmailNormalizer.normalize`.
    private let normalizedCurrentUserEmail: String
    private let participantLoader: ParticipantLoader
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext

    /// An uncached participant load result together with the `participantInfoKey` it was
    /// loaded for, stored as one value so the key/info pair cannot drift across write
    /// sites (`loadContactInfo` sets both together; the refresh path clears both).
    private struct UncachedParticipantLoad {
        let key: String
        let info: ParticipantLoader.ParticipantInfo
    }

    @State private var uncachedLoad: UncachedParticipantLoad?
    /// Bumped by `refreshParticipantInfoIfNeeded` so `participantInfoKey` changes after a
    /// `.personDisplayInfoDidChange` notification even when every snapshot field is
    /// unchanged — the key change re-triggers `.task(id:)` and reloads participant info
    /// with the contact's updated display data. Deliberate; introduced in 2b3bf9b
    /// ("Fix stale sender display names").
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
        self.normalizedCurrentUserEmail = EmailNormalizer.normalize(currentUserEmail)
        self.participantLoader = participantLoader
        self.conversationObjectID = conversationObjectID
        self.conversationContext = conversationContext
    }

    var body: some View {
        // Bind participant data once per body evaluation. The previous per-call-site
        // computed properties repeated the rollup-cache lookups and key builds for every
        // consumer (~9 lookups and 5 key builds per render); this resolution performs at
        // most one full lookup, one base lookup on a full miss, and one key build.
        let loadsParticipantInfo = ConversationRowPolicy.shouldLoadParticipantInfo(
            conversationType: snapshot.conversationType
        )
        let infoKey = participantInfoKey
        let cachedFull = loadsParticipantInfo ? cachedParticipantInfo(includePhotos: true) : nil
        // resolvedParticipantInfo's first branch returns the full entry on a hit, so the
        // base entry is consulted only on a full miss — an eager base lookup would defeat
        // the rollup cache's fast path.
        let info = loadsParticipantInfo
            ? ConversationRowPolicy.resolvedParticipantInfo(
                cachedFull: cachedFull,
                cachedBase: cachedFull == nil ? cachedParticipantInfo(includePhotos: false) : nil,
                uncached: uncachedParticipantInfo(for: infoKey)
            )
            : nil
        let fallbackName = fallbackDisplayName
        let displayName = ConversationRowPolicy.resolvedDisplayName(
            conversationType: snapshot.conversationType,
            storedDisplayName: fallbackName,
            participantInfo: info
        )
        let participantNames = ConversationRowPolicy.resolvedAvatarDisplayNames(
            conversationType: snapshot.conversationType,
            participantInfo: info
        )
        let avatarPhotos = ConversationRowPolicy.resolvedAvatarPhotos(
            conversationType: snapshot.conversationType,
            participantInfo: info
        )
        let showsGroupAvatar = ConversationRowPolicy.resolvedShowsGroupAvatar(
            snapshotShowsGroupAvatar: snapshot.showsGroupAvatar,
            conversationType: snapshot.conversationType,
            participantInfo: info
        )
        let participantLoadKey = needsParticipantLoad(
            loadsParticipantInfo: loadsParticipantInfo,
            cachedFull: cachedFull,
            infoKey: infoKey
        ) ? infoKey : nil
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
                fallbackDisplayText: fallbackName
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

        rowContent
            .task(id: participantLoadKey) {
                guard let participantLoadKey else { return }
                await loadContactInfo(for: participantLoadKey)
            }
            .onReceive(NotificationCenter.default.publisher(for: .personDisplayInfoDidChange).receive(on: DispatchQueue.main)) { notification in
                refreshParticipantInfoIfNeeded(for: notification)
            }
    }

    private var participantInfoKey: String {
        [
            conversationObjectID.uriRepresentation().absoluteString,
            snapshot.participantHash ?? "",
            snapshot.displayNameHint ?? "",
            snapshot.participantDisplayNameFingerprint,
            normalizedCurrentUserEmail,
            String(participantRefreshToken)
        ].joined(separator: "|")
    }

    /// Single rollup-cache accessor for this row; `includePhotos` selects between the
    /// base and full cache entries so the two lookups cannot drift in their other
    /// arguments.
    private func cachedParticipantInfo(includePhotos: Bool) -> ParticipantLoader.ParticipantInfo? {
        participantLoader.cachedParticipantInfo(
            conversationObjectID: conversationObjectID,
            participantHash: snapshot.participantHash,
            currentUserEmail: currentUserEmail,
            maxParticipants: 4,
            fallbackDisplayName: snapshot.displayNameHint,
            includePhotos: includePhotos
        )
    }

    /// The stored uncached load, but only when it was produced for the given key —
    /// a stale load for an outdated key must not be displayed.
    private func uncachedParticipantInfo(for participantInfoKey: String) -> ParticipantLoader.ParticipantInfo? {
        guard let uncachedLoad, uncachedLoad.key == participantInfoKey else {
            return nil
        }

        return uncachedLoad.info
    }

    private var fallbackDisplayName: String {
        PersonDisplayNameResolver.displayFallbackConversationName(
            hint: snapshot.displayNameHint,
            participantEmails: nonSelfParticipantEmails
        )
    }

    private var nonSelfParticipantEmails: [String] {
        // Snapshot emails are already normalized (ConversationSnapshot.participantEmails(from:)
        // stores EmailNormalizer.normalize output, which is idempotent), so compare them
        // against the once-normalized current-user email without re-normalizing each one.
        snapshot.participantEmails.filter { email in
            email != normalizedCurrentUserEmail
        }
    }

    /// Whether the async participant load should run, given the participant data already
    /// resolved by this body evaluation (so the check adds no extra cache lookups).
    private func needsParticipantLoad(
        loadsParticipantInfo: Bool,
        cachedFull: ParticipantLoader.ParticipantInfo?,
        infoKey: String
    ) -> Bool {
        guard loadsParticipantInfo else {
            return false
        }

        if snapshot.participantHash?.isEmpty == false {
            return cachedFull == nil
        }

        return uncachedParticipantInfo(for: infoKey) == nil
    }

    private func loadContactInfo(for participantInfoKey: String) async {
        guard ConversationRowPolicy.shouldLoadParticipantInfo(
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

        uncachedLoad = UncachedParticipantLoad(key: participantInfoKey, info: info)
    }

    private func refreshParticipantInfoIfNeeded(for notification: Notification) {
        guard ConversationRowPolicy.shouldLoadParticipantInfo(
            conversationType: snapshot.conversationType
        ) else {
            return
        }

        let changedEmails = PersonDisplayInfoChangeNotification.emails(from: notification)
        guard changedEmails.isEmpty || !Set(snapshot.participantEmails).isDisjoint(with: changedEmails) else {
            return
        }

        uncachedLoad = nil
        participantRefreshToken &+= 1
    }

    private func formatDate(_ date: Date) -> String {
        return TimestampFormatter.format(date)
    }
}
