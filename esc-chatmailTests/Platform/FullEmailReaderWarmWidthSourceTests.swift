#if os(iOS)
import UIKit
#endif
import XCTest
@testable import esc_chatmail

/// Visible rows pre-render the full reader at `FullEmailReaderWarmWidthSource.currentWidth`: the
/// screen width on iOS, the reader's last measured width on the Mac (PR E). These pin the
/// recording the Mac reads, that iOS still ignores it, and that the Mac reads it.
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

    #if os(iOS)
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
    #elseif os(macOS)
    /// A Mac screen is far wider than the reader, so rows warm at the reader's own last width, and
    /// warm no WebView at all before the first open.
    ///
    /// Revert-check: making the AppKit branch of `FullEmailReaderWarmWidthSource.currentWidth`
    /// return anything but `lastMeasuredReaderWidth` fails this.
    func testCurrentWidth_onMac_isTheRecordedReaderWidthAndNilBeforeTheFirstOpen() {
        XCTAssertNil(FullEmailReaderWarmWidthSource.currentWidth)

        FullEmailReaderWarmWidthSource.recordMeasuredReaderWidth(612)

        XCTAssertEqual(FullEmailReaderWarmWidthSource.currentWidth, 612)
    }
    #endif
}
