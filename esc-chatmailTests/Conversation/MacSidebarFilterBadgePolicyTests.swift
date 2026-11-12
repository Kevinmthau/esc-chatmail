import XCTest
@testable import esc_chatmail

/// The badge on the Mac sidebar's filter button. Pure, so these run in the iOS suite and in
/// `Mac.xctestplan`.
///
/// HONEST SCOPE: this pins the count and the words. That a count of zero draws no badge is
/// SwiftUI's documented behavior, and that `badge(_:)` on a toolbar button's menu draws one was
/// measured off screen (`docs/mac-imessage-ui-plan.md`, "Spike results"); neither has been seen
/// in the app. What VoiceOver then reads for the button has not been heard: the words are given
/// to SwiftUI as the button's accessibility value (`MacConversationSidebarSourceTests`), and
/// whether the badge's number is read as well is not known.
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

    /// The badge is a bare 1. The button's value is what says which filter that one is, in
    /// the word the menu shows for it.
    ///
    /// Revert-check: returning `String(badgeCount(for: filter))` from
    /// `MacSidebarFilterBadgePolicy.spokenValue(for:)` makes this fail: the value would be the
    /// number again.
    func testSpokenValue_isTheFiltersNameInTheMenu() {
        for filter in ConversationFilter.allCases {
            XCTAssertEqual(MacSidebarFilterBadgePolicy.spokenValue(for: filter), filter.rawValue)
        }
        XCTAssertEqual(MacSidebarFilterBadgePolicy.spokenValue(for: .unread), "Unread")
    }

    /// Revert-check: returning "Filter conversations" for every filter from
    /// `MacSidebarFilterBadgePolicy.helpText(for:)` makes this fail: the tooltip would not say
    /// what the badge counts.
    func testHelpText_withAFilterOn_saysTheListShowsOnlyThat() {
        XCTAssertEqual(MacSidebarFilterBadgePolicy.helpText(for: .unread), "Showing only: Unread")

        for filter in ConversationFilter.allCases where filter != .all {
            XCTAssertTrue(
                MacSidebarFilterBadgePolicy.helpText(for: filter).contains(filter.rawValue),
                "\(filter)"
            )
        }
    }

    /// Revert-check: returning "Showing only: All" from
    /// `MacSidebarFilterBadgePolicy.helpText(for:)` for `.all` makes this fail: with the whole
    /// mailbox showing, the tooltip says what the button is for.
    func testHelpText_allConversationsShowing_saysWhatTheButtonDoes() {
        XCTAssertEqual(MacSidebarFilterBadgePolicy.helpText(for: .all), "Filter conversations")
    }
}
