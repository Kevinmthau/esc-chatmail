import Foundation

/// Whether a message's text is drawn as large emoji with no bubble, as Messages draws a
/// message of one to three emoji (`MessageBubbleStyle.drawsLargeEmoji`;
/// `docs/mac-imessage-ui-plan.md`, PR 4).
///
/// A pure function of the text the bubble shows. A row with a stored preview shows that text
/// from its first frame, so its form, and with it its height, is known when it mounts.
enum ChatLargeEmojiPolicy {
    static let maximumEmojiCount = 3

    /// True for one to three emoji and nothing else. Whitespace between or around them is
    /// allowed and not counted.
    static func drawsLargeEmoji(_ text: String?) -> Bool {
        guard let text else { return false }
        var count = 0
        for character in text {
            if character.isWhitespace { continue }
            // The first character that is not an emoji ends the scan, so a long message costs
            // one character.
            guard isEmoji(character) else { return false }
            count += 1
            if count > maximumEmojiCount { return false }
        }
        return count > 0
    }

    /// Whether a character is drawn as an emoji. A scalar with the Unicode `Emoji` property is
    /// not enough: the digits and `#` have it, as the bases of the keycap emoji. So the
    /// character either starts with a scalar that is an emoji by default, or carries the
    /// variation selector that asks for the emoji form ("❤️", "1️⃣").
    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji
            && character.unicodeScalars.contains { $0.value == 0xFE0F }
    }
}
