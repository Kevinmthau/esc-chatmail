import SwiftUI
import XCTest
@testable import esc_chatmail

/// The conversation row's metrics and palettes (`ConversationRowMetrics`,
/// `ConversationRowPalette`). They are plain values, so these run in the iOS suite and in
/// `Mac.xctestplan`.
///
/// The iOS list's rule is that the Mac work does not move it (`docs/mac-imessage-ui-plan.md`).
/// The row's numbers and colors were literals in `ConversationRowView` until the Mac sidebar
/// needed its own; the first two tests hold the iOS values to those literals, written out again
/// here.
///
/// HONEST SCOPE: these pin the values, not that `ConversationRowView` reads every one of them
/// where it used the literal. `ConversationRowLayoutTests` mounts the row with `.iOS`, and the
/// change that made them values was checked once by drawing the iOS row before and after it and
/// comparing the pixels (`docs/mac-imessage-ui-plan.md`, "PR 2 as built").
final class ConversationRowMetricsTests: XCTestCase {
    /// Revert-check: changing any field of `ConversationRowMetrics.iOS` makes this fail.
    func testIOSMetrics_areTheRowsLiteralsFromBeforeTheyWereAValue() {
        XCTAssertEqual(
            ConversationRowMetrics.iOS,
            ConversationRowMetrics(
                unreadIndicatorDiameter: 10,
                avatarDiameter: 44,
                titleFont: .headline,
                secondaryTextFont: .subheadline,
                textColumnTopPadding: 11,
                textColumnBottomPadding: 14.5,
                titleToPreviewSpacing: 4,
                rowLeadingPadding: 8,
                unreadIndicatorToAvatarSpacing: 9,
                avatarToTextSpacing: 12,
                rowTrailingPadding: 20,
                timestampToChevronSpacing: 12,
                showsChevron: true
            )
        )
    }

    /// The name's color is nil on purpose: the row set none before, and naming one, even
    /// `primary`, would stop the name following its surroundings.
    ///
    /// Revert-check: changing any field of `ConversationRowPalette.standard` makes this fail.
    func testStandardPalette_isTheRowsColorsFromBeforeTheyWereAValue() {
        XCTAssertEqual(
            ConversationRowPalette.standard,
            ConversationRowPalette(
                title: nil,
                secondaryText: .secondary,
                unreadIndicator: .blue,
                pin: .orange,
                chevron: .tertiaryLabel
            )
        )
    }

    /// The iOS avatar is drawn at the diameter the avatar views were designed at, where every
    /// size inside them is the number it was before the diameter was a parameter.
    ///
    /// Revert-check: changing `AvatarStackView.designDiameter` makes this fail.
    func testIOSMetrics_avatarIsDrawnAtItsDesignDiameter() {
        XCTAssertEqual(ConversationRowMetrics.iOS.avatarDiameter, AvatarStackView.designDiameter)
        XCTAssertEqual(AvatarStackView.designDiameter, 44)
    }

    /// A Mac row is selected in place and pushes nothing, so it has no disclosure chevron.
    ///
    /// Revert-check: setting `showsChevron: true` in `ConversationRowMetrics.mac` makes this
    /// fail.
    func testMacMetrics_showNoChevron() {
        XCTAssertFalse(ConversationRowMetrics.mac.showsChevron)
    }

    /// On the accent color the row has to name the name's color. Left to the list, it is light
    /// only while the list has the keyboard focus, and dark on the accent color the rest of the
    /// time.
    ///
    /// Revert-check: setting `title: nil` in `ConversationRowPalette.onSelectionFill` makes this
    /// fail.
    func testOnSelectionFillPalette_namesTheTitlesColor() {
        XCTAssertEqual(ConversationRowPalette.onSelectionFill.title, .white)
    }

    /// The unread indicator's blue and the pin's orange are colors the row names, which no list
    /// changes for a selected row. On the accent color both would be lost, or clash.
    ///
    /// Revert-check: setting `unreadIndicator: .blue` in `ConversationRowPalette.onSelectionFill`
    /// makes this fail.
    func testOnSelectionFillPalette_drawsItsMarksInWhite() {
        XCTAssertEqual(ConversationRowPalette.onSelectionFill.unreadIndicator, .white)
        XCTAssertEqual(ConversationRowPalette.onSelectionFill.pin, .white)
    }
}
