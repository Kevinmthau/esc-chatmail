import XCTest
@testable import esc_chatmail

/// The badge on the Mac sidebar's filter button. Pure, so these run in the iOS suite and in
/// `Mac.xctestplan`.
///
/// HONEST SCOPE: this pins the count. That a count of zero draws no badge is SwiftUI's
/// documented behavior, and that `badge(_:)` on a toolbar button's menu draws one was measured
/// off screen (`docs/mac-imessage-ui-plan.md`, "Spike results"); neither has been seen in the
/// app.
final class MacSidebarFilterBadgePolicyTests: XCTestCase {
    /// Revert-check: returning 1 for every filter from
    /// `MacSidebarFilterBadgePolicy.badgeCount(for:)` makes this fail: the button would be
    /// badged with the whole mailbox showing.
    func testBadgeCount_allConversationsShowing_isZero() {
        XCTAssertEqual(MacSidebarFilterBadgePolicy.badgeCount(for: .all), 0)
    }

    /// Every case but `.all`, read from the enum, so a filter added later is badged too.
    ///
    /// Revert-check: returning 0 for every filter from
    /// `MacSidebarFilterBadgePolicy.badgeCount(for:)` makes this fail.
    func testBadgeCount_anyFilterOn_isOne() {
        let filtersThatHideConversations = ConversationFilter.allCases.filter { $0 != .all }
        XCTAssertFalse(filtersThatHideConversations.isEmpty)

        for filter in filtersThatHideConversations {
            XCTAssertEqual(MacSidebarFilterBadgePolicy.badgeCount(for: filter), 1, "\(filter)")
        }
    }
}
