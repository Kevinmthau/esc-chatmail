import CoreGraphics
import XCTest
@testable import esc_chatmail

/// The mouse over an attachment that can be dragged out of a Mac chat (`AttachmentDragPolicy`).
/// Pure, so it runs on both platforms.
final class AttachmentDragPolicyTests: XCTestCase {
    private typealias Policy = AttachmentDragPolicy

    /// Revert-check: returning true from `startsDrag` whatever the distance makes the first
    /// three fail: every click on an attachment would start a drag and open nothing.
    func testStartsDrag_onlyOnceThePointerHasMovedTheThreshold() {
        let press = CGPoint(x: 100, y: 100)

        XCTAssertFalse(Policy.startsDrag(from: press, to: press))
        XCTAssertFalse(Policy.startsDrag(from: press, to: CGPoint(x: 103, y: 100)))
        XCTAssertFalse(Policy.startsDrag(from: press, to: CGPoint(x: 102, y: 97)))
        XCTAssertTrue(Policy.startsDrag(from: press, to: CGPoint(x: 104, y: 100)))
        XCTAssertTrue(Policy.startsDrag(from: press, to: CGPoint(x: 100, y: 96)))
        // The distance, not either axis: 3 and 3 is 4.24.
        XCTAssertTrue(Policy.startsDrag(from: press, to: CGPoint(x: 97, y: 103)))
        XCTAssertEqual(Policy.dragThreshold, 4)
    }

    /// Revert-check: returning `releasedInside` alone makes the second fail: letting go of a
    /// drag would also open Quick Look.
    func testIsClick_onlyForAPressThatNeitherMovedNorLeft() {
        XCTAssertTrue(Policy.isClick(didStartDrag: false, releasedInside: true))
        XCTAssertFalse(Policy.isClick(didStartDrag: true, releasedInside: true))
        XCTAssertFalse(Policy.isClick(didStartDrag: false, releasedInside: false))
        XCTAssertFalse(Policy.isClick(didStartDrag: true, releasedInside: false))
    }

    /// Revert-check: returning true from `allowsCopy` makes the second fail.
    func testAllowsCopy_onlyOutsideTheApp() {
        XCTAssertTrue(Policy.allowsCopy(outsideApplication: true))
        XCTAssertFalse(Policy.allowsCopy(outsideApplication: false))
    }
}
