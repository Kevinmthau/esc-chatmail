import Foundation

/// Reduces Markdown links in plain text to their labels for preview cards.
///
/// ESPs write every link of a generated text/plain part as `[label](url)`
/// (Klaviyo does, image links included), and Markdown-native senders write a
/// linked image as `[![alt](src)](href)`. An image-only campaign's HTML carries
/// almost no text, so its plain text supplies both the card's lines and the
/// stored `cleanedSnippet`, and with the links left in those read as
/// `[label](https://...)`. Only web and mailto targets with no spaces or
/// parentheses match, so ordinary bracketed text is left alone.
///
/// The targets come back beside the text because they still carry footer and
/// skip signals the labels may not: `[Click here](https://…/unsubscribe)` is a
/// footer, `[tiktok](https://www.instagram.com/…)` a social link. Callers judge
/// the text with its targets, so stripping a link changes only what a card
/// shows, never what it keeps.
enum MarkdownLinkLabels {
    struct Result: Equatable {
        let text: String
        /// Every removed link's target (an image's source included), in the
        /// order the links were removed: inner links before the links around them.
        let targets: [String]
    }

    private static let linkRegex = try? NSRegularExpression(
        pattern: #"!?\[([^\[\]\n]*)\]\(\s*<?((?:https?://|mailto:)[^\s()<>]*)>?\s*\)"#,
        options: [.caseInsensitive]
    )

    /// A link cut off at the end of the text: an open label, or a label whose
    /// target never closes, as left by a footer trim that landed inside it.
    /// The first alternative is a linked image cut inside its outer target.
    private static let trailingPartialLinkRegex = try? NSRegularExpression(
        pattern: #"(?:\[!\[[^\[\]\n]*\]\([^\s()]*\)\]\([^\s()]*|\[?!?\[[^\[\]\n]*\]\([^\s()]*|\[?!?\[[^\[\]\n]*)$"#,
        options: []
    )

    /// A linked image takes two passes (its image, then the link around it).
    /// Markdown has no links inside links, so a third finds nothing new in
    /// anything a sender writes.
    private static let maxPasses = 3

    static func containsLink(in text: String) -> Bool {
        guard text.contains("]("), let linkRegex else {
            return false
        }

        return linkRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func replacingLinks(in text: String) -> Result {
        guard text.contains("](") else {
            return Result(text: text, targets: [])
        }

        var current = text
        var targets: [String] = []
        for _ in 0..<maxPasses {
            guard let pass = replacingLinksOnce(in: current) else {
                break
            }

            current = pass.text
            targets += pass.targets
        }

        return Result(text: current, targets: targets)
    }

    /// Drops a link cut off at the end of `text`, so trimming a snippet at a
    /// footer phrase inside a link's label or target leaves no `[label](https://`
    /// residue. Only an unclosed `[` at the very end matches.
    static func removingTrailingPartialLink(from text: String) -> String {
        RegexSanitizer.replace(in: text, regex: trailingPartialLinkRegex)
    }

    private static func replacingLinksOnce(in text: String) -> Result? {
        guard let linkRegex else {
            return nil
        }

        let nsText = text as NSString
        let matches = linkRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return nil
        }

        var replaced = ""
        var targets: [String] = []
        var cursor = 0
        for match in matches {
            replaced += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            replaced += nsText.substring(with: match.range(at: 1))
            targets.append(nsText.substring(with: match.range(at: 2)))
            cursor = NSMaxRange(match.range)
        }
        replaced += nsText.substring(from: cursor)

        return Result(text: replaced, targets: targets)
    }
}
