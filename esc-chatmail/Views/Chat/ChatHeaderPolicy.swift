import Foundation

/// What a chat's header shows and does, for each `ChatHeaderStyle`
/// (`docs/mac-imessage-ui-plan.md`, PR 3).
///
/// The iOS chat shows the conversation's name as its navigation title. The Mac's chat column
/// shows Messages' header: the avatar in the toolbar and the name in a capsule under it. A
/// header that is the toolbar's principal item cannot be both, because the Mac's toolbar is 52
/// points tall and does not grow: an avatar over a capsule is 60 points and stuck out of it at
/// both ends (the spike). So the avatar is the principal item and the capsule is a bar of its
/// own under the toolbar (`MacChatHeaderNameBar`).
enum ChatHeaderPolicy {
    /// What a chat puts at the toolbar's principal placement.
    enum PrincipalItem: Equatable {
        /// The conversation's name.
        case title
        /// The conversation's avatar, at this diameter.
        case avatar(diameter: CGFloat)
    }

    static func principalItem(for style: ChatHeaderStyle) -> PrincipalItem {
        switch style {
        case .navigationTitle:
            return .title
        case .avatarOverNameCapsule(let metrics):
            return .avatar(diameter: metrics.avatarDiameter)
        }
    }

    /// Whether the principal item is taken off the glass the Mac's toolbar puts behind its
    /// items (`ToolbarContent.macSharedBackgroundHidden`): yes for the avatar, which Messages
    /// draws bare. Behind the avatar the glass showed as a crescent under the circle.
    ///
    /// This and `ChatHeaderMetrics.principalItemCenterOffset` are one choice: the toolbar
    /// centers the item in a different place with its glass than without, and the name capsule
    /// has to sit under it.
    static func hidesPrincipalItemGlass(for style: ChatHeaderStyle) -> Bool {
        switch style {
        case .navigationTitle:
            return false
        case .avatarOverNameCapsule:
            return true
        }
    }

    /// The sizes of the bar that shows the name under the toolbar, or nil for a chat that has
    /// no such bar because its name is the navigation title.
    ///
    /// Fixed by the style, never by the conversation or by anything that loads: the bar is part
    /// of the transcript's top inset, and a bar that came or went after the chat mounted would
    /// move the transcript under its hidden anchor pass (`ChatMessagesCoordinator`).
    static func nameBarMetrics(for style: ChatHeaderStyle) -> ChatHeaderMetrics? {
        switch style {
        case .navigationTitle:
            return nil
        case .avatarOverNameCapsule(let metrics):
            return metrics
        }
    }

    /// Whether the header's name and avatar open Participants: for every conversation but a
    /// mailing list, whose participant rows are not its membership
    /// (`ChatView.allowsParticipantListPresentation`). Where they do not, the header draws them
    /// as plain views, with no chevron.
    static func opensParticipants(conversationType: ConversationType) -> Bool {
        ChatView.allowsParticipantListPresentation(conversationType: conversationType)
    }

    /// The participant info the header's avatar is drawn from: what the chat's view model
    /// loaded, and until that lands, what the rollup cache already holds for the conversation's
    /// row.
    ///
    /// A chat is opened from its row, which has usually loaded the same info, so the cache
    /// nearly always has it and the avatar comes up with its photo instead of showing initials
    /// for the moment the load takes. `cached` is not evaluated once the load has landed.
    static func participantInfo(
        loaded: ParticipantLoader.ParticipantInfo?,
        cached: @autoclosure () -> ParticipantLoader.ParticipantInfo?
    ) -> ParticipantLoader.ParticipantInfo? {
        loaded ?? cached()
    }

    /// The header's avatar: the avatar of the conversation's row in the list, from the same
    /// rules (`ConversationRowPolicy`), so the two cannot show different faces for one
    /// conversation.
    static func avatar(
        conversationType: ConversationType,
        participantInfo: ParticipantLoader.ParticipantInfo?,
        fallbackDisplayText: @autoclosure () -> String
    ) -> ChatHeaderAvatar {
        let participantNames = ConversationRowPolicy.resolvedAvatarDisplayNames(
            conversationType: conversationType,
            participantInfo: participantInfo
        )
        let showsGroupAvatar = ConversationRowPolicy.resolvedShowsGroupAvatar(
            snapshotShowsGroupAvatar: ConversationSnapshot.showsGroupAvatar(
                conversationType: conversationType
            ),
            conversationType: conversationType,
            participantInfo: participantInfo
        )
        return ChatHeaderAvatar(
            photos: ConversationRowPolicy.resolvedAvatarPhotos(
                conversationType: conversationType,
                participantInfo: participantInfo
            ),
            participantNames: participantNames,
            showsGroupAvatar: showsGroupAvatar,
            fallbackDisplayText: readsFallbackDisplayText(
                participantNames: participantNames,
                showsGroupAvatar: showsGroupAvatar
            )
                ? fallbackDisplayText()
                : nil
        )
    }

    /// Whether the avatar can draw from its fallback text at all, given the names it has and
    /// the layout they are drawn in: `AvatarStackView`'s own answer. A single avatar reads the
    /// text only for a name with no usable identity text, no name included; a group circle
    /// only with no names at all. Where it is no the text is never drawn, and `avatar` does
    /// not ask for it: the chat builds it by walking the conversation's participants in Core
    /// Data, and the header is re-evaluated with every update of the chat.
    static func readsFallbackDisplayText(participantNames: [String], showsGroupAvatar: Bool) -> Bool {
        AvatarStackView.readsFallbackDisplayText(
            participants: participantNames,
            showsGroupAvatar: showsGroupAvatar
        )
    }

    /// The name capsule's offset, moved to the nearest whole pixel of the display it is on.
    ///
    /// The measured offset is half a point (`ChatHeaderMetrics.principalItemCenterOffset`). That
    /// is one pixel on a 2x display. On a 1x display it is half a pixel, and an offset is not
    /// rounded the way a layout position is, so the capsule's edge and its text would be drawn
    /// across two pixel columns and look soft. A whole pixel there is half a point off the
    /// measured center, which cannot be seen; a blurred name can.
    ///
    /// The center was measured at 2x only. Where the toolbar puts the avatar on a 1x display
    /// has not been measured, so there the capsule may be a pixel off the avatar's center.
    ///
    /// A scale or an offset that is not a finite number is left alone: rounding it gives NaN.
    static func pixelAlignedOffset(_ offset: CGFloat, displayScale: CGFloat) -> CGFloat {
        guard offset.isFinite, displayScale.isFinite, displayScale > 0 else { return offset }
        return (offset * displayScale).rounded() / displayScale
    }
}
