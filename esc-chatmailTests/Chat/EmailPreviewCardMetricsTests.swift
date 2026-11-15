import SwiftUI
import XCTest
@testable import esc_chatmail

/// The chat cards' text sizes (`EmailPreviewCardMetrics`). Plain values, so these run in the
/// iOS suite and in `Mac.xctestplan`.
///
/// The sizes were literals in each card until the Mac's chat column needed smaller ones. The
/// first test holds the iPhone's to those literals, written out again here, so tuning the
/// Mac's cannot move the iPhone's.
///
/// HONEST SCOPE: these pin the values and which style names which, not that each card reads
/// the field its literal became, and not what a card then looks like. The cards were drawn
/// off screen in the test host with both sets when they became a value (2026-11-15); they
/// have not been seen in the app.
final class EmailPreviewCardMetricsTests: XCTestCase {
    /// Revert-check: changing any field of `EmailPreviewCardMetrics.iOS` makes this fail.
    func testIOSMetrics_areTheCardsLiteralsFromBeforeTheyWereAValue() {
        XCTAssertEqual(
            EmailPreviewCardMetrics.iOS,
            EmailPreviewCardMetrics(
                titleSize: 17,
                subtitleSize: 14,
                detailSize: 13,
                secondaryDetailSize: 12,
                labelSize: 11,
                amountSize: 28,
                linkTitleSize: 18,
                linkSourceSize: 15,
                dateTile: EmailPreviewCardMetrics.DateTile(
                    size: CGSize(width: 70, height: 92),
                    cornerRadius: 16,
                    spacing: 4,
                    monthSize: 12,
                    daySize: 30,
                    weekdaySize: 11
                ),
                cardPadding: 14,
                dateCardMinHeight: 144,
                transactionalCardMinHeight: 148,
                deployCardMinHeight: 128
            )
        )
    }

    /// Revert-check: changing any field of `EmailPreviewCardMetrics.mac` makes this fail.
    func testMacMetrics_areTheCardsAtTheMacsTextSizes() {
        XCTAssertEqual(
            EmailPreviewCardMetrics.mac,
            EmailPreviewCardMetrics(
                titleSize: 13,
                subtitleSize: 12,
                detailSize: 12,
                secondaryDetailSize: 11,
                labelSize: 11,
                amountSize: 20,
                linkTitleSize: 13,
                linkSourceSize: 11,
                dateTile: EmailPreviewCardMetrics.DateTile(
                    size: CGSize(width: 54, height: 72),
                    cornerRadius: 12,
                    spacing: 2,
                    monthSize: 10,
                    daySize: 22,
                    weekdaySize: 10
                ),
                cardPadding: 12,
                dateCardMinHeight: 116,
                transactionalCardMinHeight: 118,
                deployCardMinHeight: 104
            )
        )
    }

    /// The Mac's bubble text is 13 points. A card title above that is the oversized card the
    /// Mac's metrics exist to end, and no line of a card is larger than its title but the
    /// amount and the tile's day number.
    ///
    /// Revert-check: `titleSize: 17` in `EmailPreviewCardMetrics.mac` makes this fail.
    func testMacMetrics_noTextLineIsLargerThanTheBubbleText() {
        let mac = EmailPreviewCardMetrics.mac
        let macBubbleTextSize: CGFloat = 13

        for size in [
            mac.titleSize, mac.subtitleSize, mac.detailSize, mac.secondaryDetailSize,
            mac.labelSize, mac.linkTitleSize, mac.linkSourceSize,
            mac.dateTile.monthSize, mac.dateTile.weekdaySize
        ] {
            XCTAssertLessThanOrEqual(size, macBubbleTextSize)
        }
    }

    /// Revert-check: returning `.iOS` for every style from
    /// `MessageBubbleStyle.previewCardMetrics` makes the Mac's assertion fail; returning
    /// `.mac` for `.standard` makes the first fail.
    func testBubbleStyles_nameTheirCardsMetrics() {
        XCTAssertEqual(MessageBubbleStyle.standard.previewCardMetrics, .iOS)
        XCTAssertEqual(MessageBubbleStyle.compact.previewCardMetrics, .iOS)
        XCTAssertEqual(MessageBubbleStyle.mac.previewCardMetrics, .mac)
    }

    /// A card mounted outside a bubble draws with the iPhone's sizes.
    ///
    /// Revert-check: `defaultValue = EmailPreviewCardMetrics.mac` in
    /// `EmailPreviewCardMetricsKey` makes this fail.
    func testEnvironment_defaultsToTheIPhonesMetrics() {
        XCTAssertEqual(EnvironmentValues().emailPreviewCardMetrics, .iOS)
    }

    /// The cards' text is SF Pro, the default design, at the metrics' size.
    ///
    /// Revert-check: `design: .rounded` in `EmailPreviewCardMetrics.font(size:weight:)` makes
    /// this fail.
    func testFont_isTheDefaultDesignAtTheNamedSize() {
        XCTAssertEqual(
            EmailPreviewCardMetrics.iOS.font(\.titleSize, .semibold),
            Font.system(size: 17, weight: .semibold, design: .default)
        )
        XCTAssertEqual(
            EmailPreviewCardMetrics.mac.font(\.titleSize, .semibold),
            Font.system(size: 13, weight: .semibold, design: .default)
        )
        XCTAssertEqual(
            EmailPreviewCardMetrics.mac.font(\.detailSize),
            Font.system(size: 12, weight: .regular, design: .default)
        )
        XCTAssertNotEqual(
            EmailPreviewCardMetrics.iOS.font(\.titleSize, .semibold),
            Font.system(size: 17, weight: .semibold, design: .rounded)
        )
    }
}
