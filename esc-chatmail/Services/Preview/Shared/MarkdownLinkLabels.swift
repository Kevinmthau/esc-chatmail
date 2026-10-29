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

    /// A linked image as one link (`[![alt](src)](href)`), which `linkRegex`
    /// sees only as the image inside it, so `enclosingLinkStart` can step out
    /// of the whole thing.
    private static let linkedImageRegex = try? NSRegularExpression(
        pattern: #"\[!\[[^\[\]\n]*\]\(\s*<?(?:https?://|mailto:)[^\s()<>]*>?\s*\)\]\(\s*<?(?:https?://|mailto:)[^\s()<>]*>?\s*\)"#,
        options: [.caseInsensitive]
    )

    /// A link target's parentheses with any whitespace inside them, line
    /// breaks included (`[label](⏎https://…⏎)`), which Markdown allows and a
    /// line-by-line reader would otherwise see as two halves of no link.
    private static let paddedLinkTargetRegex = try? NSRegularExpression(
        pattern: #"\]\(\s*(<?(?:https?://|mailto:)[^\s()<>]*>?)\s*\)"#,
        options: [.caseInsensitive]
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

    /// `text` with each link that a line break splits inside its parentheses
    /// rejoined onto one line, for callers that read it line by line.
    static func joiningLinksSplitAcrossLines(in text: String) -> String {
        guard text.contains("]("), let paddedLinkTargetRegex else {
            return text
        }

        return paddedLinkTargetRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "]($1)"
        )
    }

    /// The UTF-16 range of every link in `text`, a linked image's whole
    /// `[![alt](src)](href)` beside its image's. Scanned once per text so
    /// `enclosingLinkStart` can be asked for several offsets.
    static func linkRanges(in text: String) -> [NSRange] {
        guard text.contains("](") else {
            return []
        }

        let range = NSRange(location: 0, length: (text as NSString).length)
        return [linkRegex, linkedImageRegex]
            .compactMap { $0 }
            .flatMap { $0.matches(in: text, range: range).map(\.range) }
    }

    /// The UTF-16 offset where the outermost of `linkRanges` containing
    /// `location` starts, or nil when `location` is not inside a link. A footer
    /// cut moved there drops the link whole, so no `[label](https://` residue
    /// is left behind.
    static func enclosingLinkStart(of location: Int, in linkRanges: [NSRange]) -> Int? {
        linkRanges
            .filter { $0.location < location && location < NSMaxRange($0) }
            .map(\.location)
            .min()
    }

    /// The link `text` starts with, if any: its label and its UTF-16 range. A
    /// linked image is not one (its outer label is itself an image).
    static func leadingLink(in text: String) -> (label: String, range: NSRange)? {
        guard text.hasPrefix("["), let linkRegex else {
            return nil
        }

        let nsText = text as NSString
        guard let match = linkRegex.firstMatch(
            in: text,
            options: [.anchored],
            range: NSRange(location: 0, length: nsText.length)
        ) else {
            return nil
        }

        return (nsText.substring(with: match.range(at: 1)), match.range)
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
