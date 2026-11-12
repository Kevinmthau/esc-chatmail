import XCTest
@testable import esc_chatmail

/// Which messages the Mac's transcript draws as large emoji with no bubble
/// (`ChatLargeEmojiPolicy`). Pure, so these run in the iOS suite and in `Mac.xctestplan`.
final class ChatLargeEmojiPolicyTests: XCTestCase {
    private typealias Policy = ChatLargeEmojiPolicy

    /// Revert-check: returning false from `drawsLargeEmoji` makes this fail.
    func testDrawsLargeEmoji_oneToThreeEmoji() {
        XCTAssertTrue(Policy.drawsLargeEmoji("😀"))
        XCTAssertTrue(Policy.drawsLargeEmoji("😀😀"))
        XCTAssertTrue(Policy.drawsLargeEmoji("🎉❤️👍"))
    }

    /// Revert-check: deleting the `maximumEmojiCount` check makes this fail.
    func testDrawsLargeEmoji_fourEmoji_isAnOrdinaryBubble() {
        XCTAssertEqual(Policy.maximumEmojiCount, 3)
        XCTAssertFalse(Policy.drawsLargeEmoji("😀😀😀😀"))
    }

    /// Revert-check: skipping non-emoji characters instead of returning false for them makes
    /// this fail.
    func testDrawsLargeEmoji_anyOtherText_isAnOrdinaryBubble() {
        XCTAssertFalse(Policy.drawsLargeEmoji("ok 👍"))
        XCTAssertFalse(Policy.drawsLargeEmoji("👍 ok"))
        XCTAssertFalse(Policy.drawsLargeEmoji("Thanks"))
    }

    /// Revert-check: returning `count >= 0` at the end of `drawsLargeEmoji` makes this fail: a
    /// blank message would be drawn as large emoji, which is nothing at all.
    func testDrawsLargeEmoji_nothingToDraw_isNot() {
        XCTAssertFalse(Policy.drawsLargeEmoji(nil))
        XCTAssertFalse(Policy.drawsLargeEmoji(""))
        XCTAssertFalse(Policy.drawsLargeEmoji(" \n "))
    }

    /// Revert-check: counting whitespace as a character in `drawsLargeEmoji` makes this fail.
    func testDrawsLargeEmoji_whitespaceAroundAndBetween_isNotCounted() {
        XCTAssertTrue(Policy.drawsLargeEmoji(" 😀 😀\n😀 "))
    }

    /// A family, a flag, a skin tone and a keycap are each one character made of several
    /// scalars.
    ///
    /// Revert-check: counting unicode scalars instead of characters in `drawsLargeEmoji` makes
    /// this fail.
    func testDrawsLargeEmoji_emojiOfSeveralScalars_countOnce() {
        XCTAssertTrue(Policy.drawsLargeEmoji("👨‍👩‍👧‍👦🇺🇸👍🏽"))
        XCTAssertTrue(Policy.drawsLargeEmoji("1️⃣"))
    }

    /// The digits and "#" have Unicode's `Emoji` property, as the bases of the keycaps.
    ///
    /// Revert-check: testing only `properties.isEmoji` in `isEmoji` makes this fail: "12" would
    /// be drawn 40 points tall with no bubble.
    func testDrawsLargeEmoji_digitsAndSymbolsThatAreOnlyEmojiBases_areText() {
        XCTAssertFalse(Policy.drawsLargeEmoji("12"))
        XCTAssertFalse(Policy.drawsLargeEmoji("#"))
        XCTAssertFalse(Policy.drawsLargeEmoji("*"))
        XCTAssertFalse(Policy.isEmoji("7"))
    }

    /// Revert-check: dropping the variation-selector half of `isEmoji` makes the first
    /// assertion fail.
    func testIsEmoji_textSymbolWithTheEmojiVariationSelector() {
        XCTAssertTrue(Policy.isEmoji("❤️"))
        XCTAssertTrue(Policy.isEmoji("😀"))
        XCTAssertFalse(Policy.isEmoji("a"))
    }
}
