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

    /// The row's preview line: "No messages" for a conversation without a
    /// snippet, and a blank stand-in for an empty one. The stand-in draws
    /// nothing but reserves the preview's two lines, as
    /// `GoogleDriveSharedFileCardContent.titleBlock`'s does; an empty `Text` does
    /// not, and that row measured 64pt to a one-line preview's 88pt at the
    /// default text size. An empty snippet stays blank rather than reading as
    /// "No messages", since its conversation can still hold messages: the golden
    /// corpus's `empty_rollup_does_not_scan_messages` keeps it empty on
    /// `ConversationSnapshot`, and the web row shows it blank.
    static func previewText(snippet: String?) -> String {
        guard let snippet else { return "No messages" }
        return snippet.isEmpty ? " " : snippet
    }
}
