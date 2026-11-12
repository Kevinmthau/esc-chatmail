import Foundation

/// What the chat header's avatar is drawn from: the arguments `AvatarStackView` takes, resolved
/// the way the conversation's row resolves them (`ChatHeaderPolicy.avatar`).
struct ChatHeaderAvatar {
    /// One entry per name in `participantNames`, nil where that participant has no photo.
    let photos: [ProfilePhoto?]
    let participantNames: [String]
    let showsGroupAvatar: Bool
    /// What the avatar draws initials from while it has no participant to name: before the
    /// participant load lands, and always for a mailing list. Nil where the names leave it
    /// nothing to draw (`ChatHeaderPolicy.readsFallbackDisplayText`).
    let fallbackDisplayText: String?
}
