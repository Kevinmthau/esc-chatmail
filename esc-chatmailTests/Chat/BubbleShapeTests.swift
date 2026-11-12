import SwiftUI
import XCTest
@testable import esc_chatmail

/// The outline of the Mac's bubble (`BubbleShape`): its geometry, read from the path. Pure, so
/// these run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: a path's bounds and the points it contains, not how the tail looks. The look
/// was judged from off-screen drawings (`docs/mac-imessage-ui-plan.md`, "PR 4 as built").
final class BubbleShapeTests: XCTestCase {
    private let rect = CGRect(x: 10, y: 20, width: 200, height: 60)

    private func shape(_ tail: BubbleShape.Tail?, radius: CGFloat = 17, tailWidth: CGFloat = 4) -> Path {
        BubbleShape(cornerRadius: radius, tail: tail, tailWidth: tailWidth).path(in: rect)
    }

    private func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.maxX, b.maxX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.maxY, b.maxY, accuracy: 0.01, file: file, line: line)
    }

    /// Revert-check: insetting the body by `tailWidth` in `BubbleShape.path` makes this fail:
    /// a bubble without a tail must fill the frame a bubble with one has.
    func testNoTail_isTheRoundedRectangleOfItsFrame() {
        assertRect(shape(nil).boundingRect, rect)
        // Rounded: the frame's corner is outside, a point inside the corner's curve is in.
        XCTAssertFalse(shape(nil).contains(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)))
        XCTAssertTrue(shape(nil).contains(CGPoint(x: rect.maxX - 8, y: rect.maxY - 8)))
        XCTAssertTrue(shape(nil).contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// The tail is outside the frame, on its side only, and no taller than the frame.
    ///
    /// Revert-check: drawing the tail's tip at `right` instead of `right + tailWidth` makes
    /// this fail, as does a tip below `bottom`.
    func testRightTail_reachesTailWidthPastTheRightEdgeAndNoFurther() {
        let bounds = shape(.right).boundingRect
        assertRect(bounds, CGRect(x: rect.minX, y: rect.minY, width: rect.width + 4, height: rect.height))
        // The tip is at the bottom, past the edge.
        XCTAssertTrue(shape(.right).contains(CGPoint(x: rect.maxX + 2, y: rect.maxY - 0.5)))
        // Higher up, the edge is the frame's.
        XCTAssertFalse(shape(.right).contains(CGPoint(x: rect.maxX + 2, y: rect.midY)))
        // Nothing on the other side.
        XCTAssertFalse(shape(.right).contains(CGPoint(x: rect.minX - 1, y: rect.maxY - 0.5)))
    }

    /// Revert-check: deleting the mirror transform for `.left` makes this fail.
    func testLeftTail_isTheMirrorImage() {
        let bounds = shape(.left).boundingRect
        assertRect(bounds, CGRect(x: rect.minX - 4, y: rect.minY, width: rect.width + 4, height: rect.height))
        XCTAssertTrue(shape(.left).contains(CGPoint(x: rect.minX - 2, y: rect.maxY - 0.5)))
        XCTAssertFalse(shape(.left).contains(CGPoint(x: rect.maxX + 2, y: rect.maxY - 0.5)))
    }

    /// A style without tails gives a width of 0; the outline is then the frame's.
    ///
    /// HONEST SCOPE: no revert makes this fail. Without the `tailWidth > 0` guard the shape
    /// unions a tail of no width, which has the same bounds; the guard saves that work and
    /// this pins the result either way.
    func testZeroTailWidth_drawsNoTail() {
        assertRect(shape(.right, tailWidth: 0).boundingRect, rect)
    }

    /// Revert-check: returning `cornerRadius` uncapped from `effectiveRadius` makes this fail.
    func testRadius_isCappedAtHalfTheBubblesHeight() {
        XCTAssertEqual(BubbleShape.effectiveRadius(cornerRadius: 17, size: CGSize(width: 200, height: 60)), 17)
        // A one-line bubble is a capsule.
        XCTAssertEqual(BubbleShape.effectiveRadius(cornerRadius: 17, size: CGSize(width: 200, height: 28)), 14)
        XCTAssertEqual(BubbleShape.effectiveRadius(cornerRadius: 17, size: CGSize(width: 20, height: 28)), 10)
        XCTAssertEqual(BubbleShape.effectiveRadius(cornerRadius: 17, size: .zero), 0)
    }
}
