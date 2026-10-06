import Foundation

/// Pure display-decision namespace for `ConversationRowView`, per the house
/// convention that view decisions live in `enum XPolicy` static-function
/// namespaces (see `MessageDisplayPolicy`). Moved verbatim off the view type so
/// the row's display resolution is testable without constructing the view.
enum ConversationRowPolicy {
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

    /// The row's preview line. A blank stored snippet reads as no snippet: the
    /// "No messages" a rollup recompute leaves the row showing anyway, since
    /// rollups store a blank preview as nil. One can still be stored (the RFC
    /// 2047 header repair writes its decoded text as is, and the preview repair
    /// skips a blank snippet no message can replace), and passed through as an
    /// empty string it rendered an empty `Text`, which does not reserve its two
    /// lines: that row measured 64pt to a one-line preview's 88pt at the default
    /// text size.
    static func previewText(snippet: String?) -> String {
        MessagePreviewText.nonEmpty(snippet) ?? "No messages"
    }
}
