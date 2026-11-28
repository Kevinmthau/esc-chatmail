import SwiftUI
import XCTest
@testable import esc_chatmail

/// The forwarded card's colors (architecture review 2026-11,
/// gap-accessibility-architecture#3). In the default plan and in `Mac.xctestplan`.
///
/// HONEST SCOPE: the palette only. That the card reads `colorSchemeContrast` to choose it is
/// pinned from source (`DynamicTypeAndContrastSourceTests`); no contrast was measured on a
/// screen, under Increase Contrast or otherwise.
final class ForwardedMessageCardPaletteTests: XCTestCase {
    /// The standard palette is the card's colors before the palette existed, field by field, on
    /// either bubble: nothing changes for a person who has not asked for more contrast.
    ///
    /// Revert-check: changing any standard value in
    /// `ForwardedMessageCardPalette.palette(isFromMe:contrast:)` (the sent secondary's 0.82,
    /// say) fails this.
    func testStandard_isTheCardsOldColorsFieldByField() {
        let sent = ForwardedMessageCardPalette.palette(isFromMe: true, contrast: .standard)
        XCTAssertEqual(sent.primaryText, .white)
        XCTAssertEqual(sent.secondaryText, Color.white.opacity(0.82))
        XCTAssertEqual(sent.tertiaryText, Color.white.opacity(0.66))
        XCTAssertEqual(sent.cardBackground, Color.white.opacity(0.14))
        XCTAssertEqual(sent.stroke, Color.white.opacity(0.12))

        let received = ForwardedMessageCardPalette.palette(isFromMe: false, contrast: .standard)
        XCTAssertEqual(received.primaryText, .primary)
        XCTAssertEqual(received.secondaryText, Color.secondary)
        XCTAssertEqual(received.tertiaryText, Color.secondary.opacity(0.84))
        XCTAssertEqual(received.cardBackground, Color.systemBackground.opacity(0.68))
        XCTAssertEqual(received.stroke, Color.primary.opacity(0.08))
    }

    /// With Increase Contrast the sent card's secondary and tertiary lines are opaque white, and
    /// the white fill under them is gone.
    ///
    /// Revert-check: returning the standard sent palette for `.increased` in
    /// `ForwardedMessageCardPalette.palette(isFromMe:contrast:)` fails this.
    func testIncreased_sentCard_hasOpaqueWhiteLinesAndNoFill() {
        let sent = ForwardedMessageCardPalette.palette(isFromMe: true, contrast: .increased)

        XCTAssertEqual(sent.secondaryText, .white)
        XCTAssertEqual(sent.tertiaryText, .white)
        XCTAssertEqual(sent.cardBackground, .clear)
        XCTAssertNotEqual(sent.stroke, ForwardedMessageCardPalette.palette(isFromMe: true, contrast: .standard).stroke)
    }

    /// The received card's tertiary line loses its extra opacity; the rest are system colors
    /// that already adapt.
    ///
    /// Revert-check: returning the standard received palette for `.increased` fails this.
    func testIncreased_receivedCard_tertiaryLineIsTheSystemSecondary() {
        let received = ForwardedMessageCardPalette.palette(isFromMe: false, contrast: .increased)

        XCTAssertEqual(received.tertiaryText, Color.secondary)
        XCTAssertEqual(received.secondaryText, Color.secondary)
    }
}
