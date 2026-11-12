import SwiftUI
import CoreData
import Combine

struct ConversationRowView: View {
    /// Maximum participants shown in the row's avatar stack and name rollup.
    /// This value is a `ParticipantRollupCache` key component — it must agree
    /// with the `maxParticipants: 4` literals in `ChatViewModel`, or the two
    /// surfaces silently fork the rollup cache.
    private let maxDisplayedParticipants = 4

    /// Use snapshot to avoid re-renders from unrelated Conversation property changes
    let snapshot: ConversationSnapshot

    private let currentUserEmail: String
    /// `currentUserEmail` normalized once at init so per-body key builds and
    /// self-participant filtering don't re-run `EmailNormalizer.normalize`.
    private let normalizedCurrentUserEmail: String
    private let participantLoader: ParticipantLoader
    private let conversationObjectID: NSManagedObjectID
    private let conversationContext: NSManagedObjectContext
    /// The row's sizes, spacing and fonts: `.iOS` in the iOS list, `.mac` in the Mac sidebar.
    /// Every list names its own, so neither platform gets the other's by default. The text
    /// column's padding sets the row height instead of a fixed frame, so rows grow with
    /// Dynamic Type as Messages' do.
    private let metrics: ConversationRowMetrics
    /// The row's colors: `.standard` unless the row sits on a selection fill, which only the
    /// Mac sidebar draws.
    private let palette: ConversationRowPalette

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
        participantLoader: ParticipantLoader,
        metrics: ConversationRowMetrics,
        palette: ConversationRowPalette = .standard
    ) {
        self.snapshot = snapshot
        self.currentUserEmail = currentUserEmail
        self.normalizedCurrentUserEmail = EmailNormalizer.normalize(currentUserEmail)
        self.participantLoader = participantLoader
        self.conversationObjectID = conversationObjectID
        self.conversationContext = conversationContext
        self.metrics = metrics
        self.palette = palette
    }

    /// The text column's leading edge, where the row's separator starts, as in
    /// Messages. By default a List separator starts at the row's first `Text`,
    /// which is the initials monogram of an avatar without a photo, so those rows'
    /// separators ran in under the avatar. The row's root reads this guide into
    /// `listRowSeparatorLeading`, which overrides anything the avatar contributes.
    private enum TextColumnLeadingAlignmentID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[HorizontalAlignment.leading]
        }
    }

    private static let textColumnLeading = HorizontalAlignment(TextColumnLeadingAlignmentID.self)

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
        let rowContent = HStack(spacing: metrics.avatarToTextSpacing) {
            HStack(spacing: metrics.unreadIndicatorToAvatarSpacing) {
                // Unread indicator with fixed width container
                ZStack {
                    if snapshot.inboxUnreadCount > 0 {
                        Circle()
                            .fill(palette.unreadIndicator)
                            .frame(width: metrics.unreadIndicatorDiameter, height: metrics.unreadIndicatorDiameter)
                    }
                }
                .frame(width: metrics.unreadIndicatorDiameter, height: metrics.unreadIndicatorDiameter)

                // Avatar stack
                AvatarStackView(
                    alignedAvatarPhotos: avatarPhotos,
                    participants: participantNames,
                    showsGroupAvatar: showsGroupAvatar,
                    fallbackDisplayText: fallbackName,
                    diameter: metrics.avatarDiameter
                )
                    .frame(width: metrics.avatarDiameter, height: metrics.avatarDiameter)
            }

            VStack(alignment: .leading, spacing: metrics.titleToPreviewSpacing) {
                // Top row: Name, date, and chevron
                HStack {
                    HStack(spacing: 4) {
                        if snapshot.pinned {
                            Image(systemName: "pin.fill")
                                .font(.footnote)
                                .foregroundColor(palette.pin)
                        }

                        Text(displayName)
                            .font(metrics.titleFont)
                            // Nil in the standard palette, which leaves the name's color to
                            // the row's surroundings, as before the row had a palette.
                            .foregroundColor(palette.title)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: metrics.timestampToChevronSpacing) {
                        if let date = snapshot.lastMessageDate {
                            Text(formatDate(date))
                                .font(metrics.secondaryTextFont)
                                .foregroundColor(palette.secondaryText)
                                // One line, so the timestamp never makes its row
                                // alone taller: beside a long title the stack can
                                // give it less than its width, and at accessibility
                                // text sizes "Yesterday" wrapped. It truncates there
                                // instead. It takes no layout priority: kept whole,
                                // it could leave a long title only an ellipsis at
                                // the largest sizes.
                                .lineLimit(1)
                        }

                        if metrics.showsChevron {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(palette.chevron)
                        }
                    }
                }

                // Bottom row: snippet only. Both lines are reserved so a
                // one-line preview keeps the full row height, as in Messages.
                Text(ConversationRowPolicy.previewText(snippet: snapshot.snippet))
                    .font(metrics.secondaryTextFont)
                    .foregroundColor(palette.secondaryText)
                    .lineLimit(2, reservesSpace: true)
            }
            // On the text column, not the row, so the avatar and unread dot stay centered
            // on the full row height.
            .padding(.top, metrics.textColumnTopPadding)
            .padding(.bottom, metrics.textColumnBottomPadding)
            .alignmentGuide(Self.textColumnLeading) { $0[.leading] }
        }
        .padding(.leading, metrics.rowLeadingPadding)
        .padding(.trailing, metrics.rowTrailingPadding)
        .alignmentGuide(.listRowSeparatorLeading) { $0[Self.textColumnLeading] }

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
            maxParticipants: maxDisplayedParticipants,
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
        // Snapshot emails are already normalized (ConversationSnapshot.participantFields(from:)
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
            maxParticipants: maxDisplayedParticipants,
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
