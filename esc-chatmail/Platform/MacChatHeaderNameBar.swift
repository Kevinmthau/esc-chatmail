#if os(macOS)
import SwiftUI

/// The lower half of the Mac chat header: the conversation's name in a glass capsule, in a bar
/// under the window's toolbar, as in Messages (`docs/mac-imessage-ui-plan.md`, PR 3). The upper
/// half is the avatar in the toolbar (`ChatHeaderAvatarButton`); a click on either opens
/// Participants (`ChatHeaderPolicy.opensParticipants`).
///
/// The bar is `metrics.nameBarHeight` tall whatever the name is, and as wide as the chat
/// column. Only the capsule draws and takes clicks; the rest of the bar is empty, so the
/// transcript shows and scrolls beneath it.
struct MacChatHeaderNameBar: View {
    let metrics: ChatHeaderMetrics
    let name: String
    let opensParticipants: Bool
    let onOpenParticipants: () -> Void

    var body: some View {
        ChatHeaderParticipantsButton(opensParticipants: opensParticipants, action: onOpenParticipants) {
            HStack(spacing: metrics.nameToChevronSpacing) {
                Text(name)
                    .font(metrics.nameFont)
                    // One line, truncated: a long name must not make the bar taller.
                    .lineLimit(1)
                    .truncationMode(.tail)

                if opensParticipants {
                    // Says the capsule opens something, as Messages' does. Not part of the
                    // name, so not read out with it.
                    Image(systemName: "chevron.right")
                        .font(metrics.chevronFont)
                        // A hierarchical style, like the name's own default color, and not a
                        // system color by name: glass gives its content a light or a dark
                        // look to suit what is behind it, and a named color follows the
                        // window's appearance instead, so it could part ways with the name
                        // beside it.
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, metrics.nameCapsuleHorizontalPadding)
            .frame(height: metrics.nameCapsuleHeight)
            // The whole capsule takes the click, not only the text in it.
            .contentShape(Capsule())
        }
        // Interactive glass answers a press, so only where a click does something.
        .glassEffect(.regular.interactive(opensParticipants), in: Capsule())
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, metrics.nameBarHorizontalPadding)
        .frame(maxWidth: .infinity)
        // A fixed height, not the capsule's own plus padding: the bar is part of the
        // transcript's top inset, which must be the same for every chat and never change after
        // the chat mounts (`ChatHeaderMetrics.nameBarHeight`).
        .frame(height: metrics.nameBarHeight)
        // Under the avatar: the toolbar centers its principal item this far right of the chat
        // column's center (`ChatHeaderMetrics.principalItemCenterOffset`).
        .offset(x: metrics.principalItemCenterOffset)
    }
}
#endif
