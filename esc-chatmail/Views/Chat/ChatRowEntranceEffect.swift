import SwiftUI

/// The iMessage-style rise-and-fade a transcript row plays when the user's own
/// send appends it (`VirtualScrollState.localSendAppendedMessageIDs`). Every
/// other row — initial load, pagination, sync inserts, the echo that replaces a
/// sent row in place — appears without it.
///
/// Drawn with `offset` and `opacity` only, which move pixels without changing
/// layout: the row takes its full height in the frame it is published, so the
/// content size grows in one step and the coordinator's bottom scroll lands on
/// the real bottom. Animating the insertion itself (a `.transition` published
/// inside `withAnimation`) would animate the content size, and a scroll issued
/// while the content size is animating is clamped to the mid-animation size and
/// never re-targeted — the same short landing `ChatBottomInsetPolicy`'s
/// spacer records. It also stays out of the bottom-anchor geometry the
/// coordinator's follow and past-end correction read.
struct ChatRowEntranceEffect: ViewModifier {
    /// Read once, when the row's view is created; later values are ignored so a
    /// re-render (or the set being cleared) cannot replay or cut the entrance.
    let animatesEntrance: Bool

    @State private var hasEntered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Starts below its resting place by about a third of a one-line bubble,
    /// as if rising out of the composer.
    private static let entranceOffset: CGFloat = 14
    private static let entranceAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    init(animatesEntrance: Bool) {
        self.animatesEntrance = animatesEntrance
        _hasEntered = State(initialValue: !animatesEntrance)
    }

    func body(content: Content) -> some View {
        content
            .opacity(hasEntered ? 1 : 0)
            .offset(y: hasEntered || reduceMotion ? 0 : Self.entranceOffset)
            .onAppear {
                guard !hasEntered else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.entranceAnimation) {
                    hasEntered = true
                }
            }
    }
}
