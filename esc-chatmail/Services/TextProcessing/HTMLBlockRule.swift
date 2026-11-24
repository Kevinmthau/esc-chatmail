import Foundation

/// A rule that removes `start…>…close` blocks (`<head\b[^>]*>[\s\S]*?</head>`
/// and the like) through `HTMLMarkupScan.replacingBlocks`, with the result
/// the regex's matches gave and none of its rereading.
struct HTMLBlockRule {
    let start: NSRegularExpression
    let close: NSRegularExpression
    /// Whether the block's body starts after the first `>` past `start`
    /// (`[^>]*>`), not right after it.
    let readsToTagEnd: Bool

    /// `start` is the regex up to the tag's attributes (`<head\b`, `<script`,
    /// `<!--`), `close` the text that ends the block; both take `options`.
    init?(start: String, close: String, readsToTagEnd: Bool, options: NSRegularExpression.Options) {
        guard let startRegex = try? NSRegularExpression(pattern: start, options: options),
              let closeRegex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: close),
                options: options
              ) else {
            return nil
        }
        self.start = startRegex
        self.close = closeRegex
        self.readsToTagEnd = readsToTagEnd
    }

    func removingBlocks(from text: String) -> String {
        HTMLMarkupScan.replacingBlocks(
            in: text,
            start: start,
            readsToTagEnd: readsToTagEnd,
            close: close,
            with: ""
        )
    }
}
