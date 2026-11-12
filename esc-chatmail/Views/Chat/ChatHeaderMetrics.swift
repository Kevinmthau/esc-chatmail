import SwiftUI

/// The sizes and fonts of the header a chat draws in the `.avatarOverNameCapsule` style
/// (`ChatHeaderStyle`), as a value, the way `ConversationRowMetrics` holds the row's.
struct ChatHeaderMetrics: Equatable {
    /// The avatar in the toolbar. `AvatarStackView` draws at whatever diameter it is given.
    let avatarDiameter: CGFloat
    /// The height of the bar the name capsule sits in, and so what the bar adds to the
    /// transcript's top inset. The bar is exactly this tall for every chat and every name: the
    /// transcript's reveal pass must not see its viewport change height after it mounts
    /// (`ChatMessagesCoordinator`), and `MacChatHeaderNameBarLayoutTests` pins it.
    let nameBarHeight: CGFloat
    /// The capsule's own height. It is centered in the bar.
    let nameCapsuleHeight: CGFloat
    /// Between the capsule's ends and its text.
    let nameCapsuleHorizontalPadding: CGFloat
    /// Between the bar's edges and the capsule: a long name truncates this far short of the
    /// chat column's edges.
    ///
    /// It has to stay above 20 points. Drawn off screen, a glass capsule that came within 20
    /// points of both edges of the transcript it sits over took the whole transcript out of the
    /// drawing, at every width tried; at 22 points and more the transcript drew. The layout was
    /// the same either way. Whether the app loses the transcript the same way is not known,
    /// because it has not been seen either way, so the capsule is kept well clear
    /// (`MacChatHeaderNameBarLayoutTests`; `docs/mac-imessage-ui-plan.md`, "PR 3 as built").
    let nameBarHorizontalPadding: CGFloat
    let nameFont: Font
    let nameToChevronSpacing: CGFloat
    /// The disclosure chevron after the name, drawn where a click on the capsule opens
    /// Participants.
    let chevronFont: Font
    /// How far right of the chat column's center the capsule's center sits, to put it under the
    /// avatar: the toolbar centers its principal item this far right of the column's center.
    /// The number depends on whether the item keeps the toolbar's glass
    /// (`ChatHeaderPolicy.hidesPrincipalItemGlass`).
    let principalItemCenterOffset: CGFloat
}

extension ChatHeaderMetrics {
    /// The Mac's header, from the spike's measurements on macOS 27.2
    /// (`docs/mac-imessage-ui-plan.md`, "Spike results"):
    ///
    /// - The window's toolbar is 52 points tall and does not grow. A 40-point avatar fits in it
    ///   as the principal item, 6 to 46 points from the window's top.
    /// - A 30-point bar under the toolbar starts the transcript 82 points from the window's top;
    ///   Messages' header is about 79.
    /// - The toolbar centers its principal item 2.5 points right of the chat column's center, at
    ///   both window widths tried and whatever the trailing item's width.
    ///
    /// That last number is for an item on the toolbar's glass, which the avatar is not
    /// (`ChatHeaderPolicy.hidesPrincipalItemGlass`). Without the glass the toolbar centers the
    /// item 0.5 points right of the column's center: measured with the header's own views
    /// under a real window toolbar, in the test host on macOS 27.2, at window widths of 900 and
    /// 1200 points, beside the New Message button and the chat's own menu
    /// (`docs/mac-imessage-ui-plan.md`, "PR 3 as built").
    ///
    /// The capsule's own numbers (22 points tall, text at 11 points, which is `.subheadline` on
    /// macOS) are a first reading of a screenshot of Messages on macOS 26, not a measurement,
    /// and none of this has been seen in the app.
    static let mac = ChatHeaderMetrics(
        avatarDiameter: 40,
        nameBarHeight: 30,
        nameCapsuleHeight: 22,
        nameCapsuleHorizontalPadding: 10,
        nameBarHorizontalPadding: 48,
        nameFont: .subheadline.weight(.medium),
        nameToChevronSpacing: 3,
        chevronFont: .system(size: 8, weight: .bold),
        principalItemCenterOffset: 0.5
    )
}
