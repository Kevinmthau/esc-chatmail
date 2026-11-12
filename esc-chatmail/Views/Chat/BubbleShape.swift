import SwiftUI

/// The outline of a Messages-style bubble: a rounded rectangle, and on the last bubble of a
/// run a tail at its bottom corner (`docs/mac-imessage-ui-plan.md`, PR 4).
///
/// The tail is drawn outside the rectangle the shape is given, `tailWidth` points past the edge
/// it is on. So a bubble with a tail and one without have the same frame, and the row keeps
/// those points free on that side for every bubble (`MessageBubbleStyle.bubbleTailWidth`):
/// the bubbles of a run line up, and a tail arriving or leaving moves nothing.
struct BubbleShape: Shape {
    /// Which bottom corner the tail is on, in the drawing's own coordinates. A shape is not
    /// mirrored in a right-to-left layout, so the caller picks the side
    /// (`MessageBubbleRowPolicy.tail`).
    enum Tail: Equatable {
        case left
        case right
    }

    /// Capped at half the bubble's height, so a one-line bubble is a capsule.
    var cornerRadius: CGFloat
    var tail: Tail?
    var tailWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = Self.effectiveRadius(cornerRadius: cornerRadius, size: rect.size)
        let body = Path(roundedRect: rect, cornerRadius: radius)
        guard let tail, tailWidth > 0, radius > 0 else { return body }

        // Drawn for a tail on the right, then mirrored.
        let right = rect.maxX
        let bottom = rect.maxY
        var tailPath = Path()
        // From the right edge, where the bottom corner's curve starts, out to the tip...
        tailPath.move(to: CGPoint(x: right, y: bottom - radius))
        tailPath.addQuadCurve(
            to: CGPoint(x: right + tailWidth, y: bottom),
            control: CGPoint(x: right, y: bottom - radius * 0.1)
        )
        // ...and back under the corner to a point on its curve.
        tailPath.addQuadCurve(
            to: CGPoint(x: right - radius * 0.5, y: bottom - radius * 0.134),
            control: CGPoint(x: right - radius * 0.05, y: bottom - radius * 0.02)
        )
        tailPath.closeSubpath()

        if tail == .left {
            let mirror = CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
            tailPath = tailPath.applying(mirror)
        }
        // A union, not a second subpath: the tail overlaps the rectangle's corner, and two
        // subpaths wound in opposite directions fill their overlap as a hole. The first
        // drawing showed exactly that, a sliver of tail beside a notched corner.
        return body.union(tailPath)
    }

    /// The corner radius actually drawn for a bubble of the given size.
    static func effectiveRadius(cornerRadius: CGFloat, size: CGSize) -> CGFloat {
        max(0, min(cornerRadius, size.height / 2, size.width / 2))
    }
}
