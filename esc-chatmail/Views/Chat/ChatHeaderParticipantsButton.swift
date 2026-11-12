import SwiftUI

/// A part of the chat header that opens Participants when clicked: the avatar in the toolbar,
/// or the name capsule under it (`ChatHeaderAvatarButton`, `MacChatHeaderNameBar`).
///
/// Where the header does not open Participants (`ChatHeaderPolicy.opensParticipants`) the label
/// is drawn as it is, not as a disabled button: a disabled button is dimmed, and a mailing
/// list's name and avatar are not unavailable, only not clickable. The two branches are one
/// conversation's for its whole life, since its type does not change while its chat is open.
struct ChatHeaderParticipantsButton<Label: View>: View {
    let opensParticipants: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if opensParticipants {
            Button(action: action, label: label)
                // Plain: the label is the whole control. A bordered button would draw its own
                // bezel around the avatar and inside the capsule.
                .buttonStyle(.plain)
        } else {
            label()
        }
    }
}
