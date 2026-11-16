import SwiftUI

/// A part of the chat header that opens Participants when clicked: the avatar in the toolbar,
/// or the name capsule under it (`ChatHeaderAvatarButton`, `MacChatHeaderNameBar`).
///
/// Every conversation's header is one, a mailing list's included: its sheet lists the list's
/// senders (`ParticipantsListPolicy`).
struct ChatHeaderParticipantsButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            // Plain: the label is the whole control. A bordered button would draw its own
            // bezel around the avatar and inside the capsule.
            .buttonStyle(.plain)
    }
}
