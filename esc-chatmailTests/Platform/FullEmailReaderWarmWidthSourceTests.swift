import UIKit
import XCTest
@testable import esc_chatmail

/// Visible rows pre-render the full reader at `FullEmailReaderWarmWidthSource.currentWidth`: the
/// screen width on iOS, the reader's last measured width on the Mac (PR E). The Mac branch cannot
/// run until the test target gains macOS (Mac plan, PR F); these pin the recording it reads and
/// that iOS still ignores it.
@MainActor
final class FullEmailReaderWarmWidthSourceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FullEmailReaderWarmWidthSource.resetForTesting()
    }

    override func tearDown() {
        FullEmailReaderWarmWidthSource.resetForTesting()
        super.tearDown()
    }

    /// A reader that has not laid out yet reports a zero width; warming at it would never match a
    /// checkout.
    ///
    /// Revert-check: removing the guard in `FullEmailReaderWarmWidthSource.recordMeasuredReaderWidth`
    /// fails this.
    func testRecordMeasuredReaderWidth_unmeasuredOrInvalidWidths_areIgnored() {
        for width: CGFloat in [0, 1, -320, .infinity, .nan] {
            FullEmailReaderWarmWidthSource.recordMeasuredReaderWidth(width)
        }

        XCTAssertNil(FullEmailReaderWarmWidthSource.lastMeasuredReaderWidth)
    }

    func testRecordMeasuredReaderWidth_afterAResize_keepsTheLatestWidth() {
        FullEmailReaderWarmWidthSource.recordMeasuredReaderWidth(390)
        FullEmailReaderWarmWidthSource.recordMeasuredReaderWidth(412.5)

        XCTAssertEqual(FullEmailReaderWarmWidthSource.lastMeasuredReaderWidth, 412.5)
    }

    /// iOS keeps warming at the scene's screen width, as before the Mac port.
    ///
    /// Revert-check: making `FullEmailReaderWarmWidthSource.currentWidth` return
    /// `lastMeasuredReaderWidth` on iOS fails this.
    func testCurrentWidth_onIOS_isTheSceneScreenWidthNotTheRecordedReaderWidth() {
        FullEmailReaderWarmWidthSource.recordMeasuredReaderWidth(123)

        XCTAssertEqual(
            FullEmailReaderWarmWidthSource.currentWidth,
            FullEmailWebViewMetrics.activeWindowScene()?.screen.bounds.width
        )
        XCTAssertNotEqual(FullEmailReaderWarmWidthSource.currentWidth, 123)
    }
}
