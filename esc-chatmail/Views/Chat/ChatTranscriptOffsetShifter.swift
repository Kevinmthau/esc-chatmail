import SwiftUI

/// Scrolls the chat transcript to the offsets `ChatBottomInsetPolicy.shift`
/// plans when its bottom inset changes, so the content above the composer
/// stays in place instead of sliding under the keyboard. The policy decides;
/// this modifier only tracks the offset and performs the scroll.
///
/// Mechanism: a `ScrollPosition` binding plus the offset tracked by
/// `onScrollGeometryChange`, scrolled with `ScrollPosition.scrollTo(y:)`. A
/// simulator probe of every candidate found it the only one that lands exactly
/// both at the bottom and scrolled up under the transcript's `LazyVStack`
/// (±1.3pt), provided the spacer growth is applied without animation
/// (`ChatBottomInsetPolicy.SpacerTransition.immediate`). The binding costs no
/// body evaluations during scrolling, and it left the initial reveal
/// unchanged in the real chat view. The iOS 17 alternatives
/// (`ScrollViewProxy.scrollTo` with a fractional anchor on the bottom anchor
/// or the content) depend on the lazy stack's size estimates once the bottom
/// anchor is unrealized and were 30-200pt off.
///
/// Gated to iOS 26 and later (open-ended), the versions it was measured on:
/// the full scenario matrix on iOS 26.5 and a subset on iOS 27.0, both in the
/// simulator. The APIs exist from iOS 18, but a coordinate difference there
/// would misplace every keyboard show; the coordinator no longer scrolls at
/// the bottom when the shift is active (its settle check only corrects a
/// short landing that started at the bottom). Earlier versions keep the
/// coordinator's scroll-to-bottom path.
struct ChatTranscriptOffsetShifter: ViewModifier {
    /// One planned scroll. `id` keeps back-to-back identical requests (two
    /// wrapped draft lines of equal height) distinct for `onChange`.
    struct Request: Equatable {
        let id: UUID
        let shift: ChatBottomInsetPolicy.Shift
    }

    /// Scroll and gesture state the owning view reads when planning a shift.
    /// A reference type held in `@State`: it is fed by per-frame geometry
    /// and scroll updates, and publishing those would invalidate the whole
    /// chat body on every scroll frame.
    final class Tracking {
        /// Offset in content coordinates (0 = content top). Starts at the
        /// top: `onScrollGeometryChange` reports changes only, and a
        /// transcript that never scrolled (shorter than the viewport) is
        /// still at its `.top` default anchor.
        var contentOffsetY: CGFloat = 0
        /// Bottom edge of the trailing 1pt anchor in scroll-frame coordinates;
        /// nil while the lazy stack has not realized it.
        var bottomAnchorMaxY: CGFloat?
        var viewportHeight: CGFloat?
        /// The scroll view is tracking, interacting or decelerating, i.e. the
        /// reader is moving it (`ChatBottomInsetPolicy.isInteractiveDismissal`).
        var isUserScrollInteractionActive = false
        var lastUserScrollInteractionEndedAt: TimeInterval?
        var shiftState = ChatBottomInsetPolicy.ShiftState()
    }

    static var isSupported: Bool {
        if #available(iOS 26.0, *) {
            return true
        } else {
            return false
        }
    }

    let request: Request?
    let tracking: Tracking
    /// Called when the reader starts moving the scroll view by any means
    /// (drag, trackpad, mouse wheel), not only the transcript's drag gesture.
    let onUserScrollInteractionBegan: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.modifier(
                ScrollPositionShift(
                    request: request,
                    tracking: tracking,
                    onUserScrollInteractionBegan: onUserScrollInteractionBegan
                )
            )
        } else {
            content
        }
    }
}

extension ChatTranscriptOffsetShifter {
    @available(iOS 26.0, *)
    private struct ScrollPositionShift: ViewModifier {
        let request: Request?
        let tracking: Tracking
        let onUserScrollInteractionBegan: () -> Void

        @State private var position = ScrollPosition()

        private static func isUserDriven(_ phase: ScrollPhase) -> Bool {
            phase == .tracking || phase == .interacting || phase == .decelerating
        }

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // `scrollTo(y:)` takes content coordinates (0 = content
                    // top), but `contentOffset` is inset-relative (-116 at the
                    // top under the navigation bar on iPhone 17 Pro). The raw
                    // value made every probe shift 116pt wrong.
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, contentOffsetY in
                    tracking.contentOffsetY = contentOffsetY
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    // Refreshes the tracked offset with the geometry the phase
                    // change carries, e.g. where a drag or deceleration came
                    // to rest. It does not cover the end of a programmatic
                    // `ScrollPosition` animation: a two-step keyboard's return
                    // still lands ~3pt off in the simulator.
                    tracking.contentOffsetY =
                        context.geometry.contentOffset.y + context.geometry.contentInsets.top
                    let wasUserDriven = Self.isUserDriven(oldPhase)
                    let isUserDriven = Self.isUserDriven(newPhase)
                    tracking.isUserScrollInteractionActive = isUserDriven
                    if isUserDriven {
                        ChatBottomInsetPolicy.userDidTakeOverScroll(state: &tracking.shiftState)
                        if !wasUserDriven {
                            onUserScrollInteractionBegan()
                        }
                    } else if wasUserDriven {
                        tracking.lastUserScrollInteractionEndedAt =
                            ProcessInfo.processInfo.systemUptime
                    }
                }
                .onChange(of: request) { _, request in
                    guard let request else { return }
                    let targetY = request.shift.targetY
                    if let duration = request.shift.animationDuration {
                        withAnimation(.easeOut(duration: duration)) {
                            position.scrollTo(y: targetY)
                        }
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            position.scrollTo(y: targetY)
                        }
                    }
                }
        }
    }
}
