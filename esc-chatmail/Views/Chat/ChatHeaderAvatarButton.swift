import SwiftUI

/// The conversation's avatar as a chat's principal toolbar item: the header of the
/// `.avatarOverNameCapsule` style, which only the Mac's chat column uses (`ChatHeaderStyle`).
/// A click opens Participants, as a click on the name capsule under it does.
///
/// It is the row's avatar (`AvatarStackView`), drawn from the row's rules
/// (`ChatHeaderPolicy.avatar`). Its frame is the diameter whatever it draws, so a photo that
/// arrives after the chat opens changes no layout.
struct ChatHeaderAvatarButton: View {
    let avatar: ChatHeaderAvatar
    let diameter: CGFloat
    let opensParticipants: Bool
    let onOpenParticipants: () -> Void

    var body: some View {
        ChatHeaderParticipantsButton(opensParticipants: opensParticipants, action: onOpenParticipants) {
            AvatarStackView(
                alignedAvatarPhotos: avatar.photos,
                participants: avatar.participantNames,
                showsGroupAvatar: avatar.showsGroupAvatar,
                fallbackDisplayText: avatar.fallbackDisplayText,
                diameter: diameter
            )
            .frame(width: diameter, height: diameter)
            // The whole circle takes the click, not only the pixels the avatar draws.
            .contentShape(Circle())
        }
        // The name capsule under the avatar is the same control with the same action, and it
        // carries the conversation's name. Announcing both would read the header twice.
        .accessibilityHidden(true)
    }
}
