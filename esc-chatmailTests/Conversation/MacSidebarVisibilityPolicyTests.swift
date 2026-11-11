import SwiftUI
import XCTest
@testable import esc_chatmail

/// When the Mac mailbox puts its sidebar back. The policy takes and returns SwiftUI's own
/// visibility values, so these run in the iOS suite and in `Mac.xctestplan`.
///
/// HONEST SCOPE: this pins the rule, not that `MacMailboxView` applies it, or what the split view
/// does with the value it is given. That was measured in a throwaway program, not in the app
/// (`MacSidebarVisibilityPolicy`).
final class MacSidebarVisibilityPolicyTests: XCTestCase {
    /// The window has no control that reopens a closed sidebar, so the view has to.
    ///
    /// Revert-check: making `MacSidebarVisibilityPolicy.correction` return nil for every value
    /// makes this fail: a sidebar dragged closed would stay closed.
    func testCorrection_sidebarClosed_putsBothColumnsBack() {
        XCTAssertEqual(MacSidebarVisibilityPolicy.correction(for: .detailOnly), .all)
    }

    /// Nil means the view writes nothing, so setting `.all` cannot start another round.
    ///
    /// Revert-check: making `MacSidebarVisibilityPolicy.correction` return `.all` for every
    /// value makes this fail.
    func testCorrection_bothColumnsShowing_changesNothing() {
        XCTAssertNil(MacSidebarVisibilityPolicy.correction(for: .all))
    }

    /// In a two-column split view this shows the sidebar too, so there is nothing to put back.
    ///
    /// `.automatic` is not pinned: what it compares equal to depends on the platform. On an
    /// iPhone simulator it equals `.detailOnly`, which failed an assertion written here first.
    func testCorrection_doubleColumn_changesNothing() {
        XCTAssertNil(MacSidebarVisibilityPolicy.correction(for: .doubleColumn))
    }
}
