import Foundation
import SwiftSoup

/// DOM-based plain-text extractor.
///
/// Replaces the regex pipeline in `TextProcessing.extractPlainText` with a
/// single SwiftSoup tree walk that emits paragraph-aware whitespace.
///
/// Differences from the legacy regex extractor that callers should know:
/// - Whitespace between inline elements is preserved as a single space (matching
///   browser behavior). Legacy code sometimes left double spaces around tags.
/// - Block elements (`p`, `div`, `h1-6`, `li`, `tr`, `table`, etc.) emit a
///   trailing newline; consecutive block boundaries collapse to at most two.
/// - `<br>` emits a newline; consecutive `<br>` pairs emit a paragraph break.
/// - `<script>`, `<style>`, `<head>`, and HTML comments are skipped entirely.
/// - HTML entities are decoded by SwiftSoup as part of `text()`, so the
///   downstream caller does not need a second `decodeHTMLEntities` pass.
enum EmailDOMTextExtractor {

    /// Extracts paragraph-aware plain text from an entire parsed document.
    static func paragraphAwareText(from document: SwiftSoup.Document) -> String {
        let root: Element = document.body() ?? document
        let buffer = TextBuffer()
        walk(node: root, into: buffer)
        return normalize(buffer.string)
    }

    /// Extracts paragraph-aware plain text from a subtree.
    static func paragraphAwareText(from element: Element) -> String {
        let buffer = TextBuffer()
        walk(node: element, into: buffer)
        return normalize(buffer.string)
    }

    // MARK: - Walk

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "nav",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre",
        "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr",
        "address", "figure", "figcaption", "hr"
    ]

    private static let cellTags: Set<String> = ["td", "th"]

    /// Tags whose subtree should not contribute to the visible text.
    private static let invisibleTags: Set<String> = [
        "script", "style", "head", "title", "meta", "link", "noscript", "template"
    ]

    private static func walk(node: Node, into buffer: TextBuffer) {
        if let textNode = node as? TextNode {
            // SwiftSoup's TextNode.text() returns decoded text.
            buffer.appendText(textNode.text())
            return
        }
        guard let element = node as? Element else {
            return
        }

        let tag = element.tagNameNormal()

        if invisibleTags.contains(tag) {
            return
        }

        switch tag {
        case "br":
            buffer.appendNewline()
            return
        case "hr":
            buffer.appendParagraphBreak()
            return
        case "img":
            // Skip alt text by default; emails frequently use it for tracking
            // pixels or for unhelpful "image: 1x1.png" strings. Callers that
            // want alt text can opt in by traversing the DOM themselves.
            return
        default:
            break
        }

        let isBlock = blockTags.contains(tag)
        let isCell = cellTags.contains(tag)

        if isBlock {
            buffer.flushPendingInlineSpace()
            buffer.markBlockBoundary()
        }

        for child in element.getChildNodes() {
            walk(node: child, into: buffer)
        }

        if isCell {
            // Cells get a trailing space so adjacent <td>FROM</td><td>foo</td>
            // produces "FROM foo" rather than "FROMfoo".
            buffer.appendInlineSpace()
        }
        if isBlock {
            buffer.markBlockBoundary()
        }
    }

    // MARK: - Buffer

    private final class TextBuffer {
        private(set) var string: String = ""
        private var pendingInlineSpace = false
        private var blockBoundary = true   // suppresses leading whitespace

        func appendText(_ text: String) {
            guard !text.isEmpty else { return }

            // Strip zero-width characters that show up in marketing emails.
            let cleaned = stripZeroWidth(text)
            guard !cleaned.isEmpty else { return }

            var startIndex = cleaned.startIndex
            // Skip leading whitespace if we're at a block boundary.
            if blockBoundary {
                while startIndex < cleaned.endIndex, cleaned[startIndex].isWhitespaceForCollapse {
                    startIndex = cleaned.index(after: startIndex)
                }
                if startIndex == cleaned.endIndex {
                    return
                }
            }

            // Collapse interior whitespace runs to single spaces.
            var collapsed = ""
            collapsed.reserveCapacity(cleaned.distance(from: startIndex, to: cleaned.endIndex))
            var lastWasWhitespace = false
            for char in cleaned[startIndex...] {
                if char.isWhitespaceForCollapse {
                    if !lastWasWhitespace {
                        collapsed.append(" ")
                    }
                    lastWasWhitespace = true
                } else {
                    collapsed.append(char)
                    lastWasWhitespace = false
                }
            }

            if pendingInlineSpace || (collapsed.first == " " && !string.isEmpty) {
                if !string.hasSuffix(" ") && !string.hasSuffix("\n") {
                    string.append(" ")
                }
            }

            // Drop leading whitespace from the collapsed chunk; we already
            // emitted it (or didn't need to) above.
            let trimmed: Substring
            if collapsed.first == " " {
                trimmed = collapsed.dropFirst()
            } else {
                trimmed = Substring(collapsed)
            }
            if trimmed.isEmpty { return }

            string.append(contentsOf: trimmed)
            pendingInlineSpace = collapsed.last == " "
            blockBoundary = false
        }

        func appendInlineSpace() {
            pendingInlineSpace = true
        }

        func flushPendingInlineSpace() {
            pendingInlineSpace = false
        }

        func appendNewline() {
            pendingInlineSpace = false
            string.append("\n")
            blockBoundary = false
        }

        func appendParagraphBreak() {
            pendingInlineSpace = false
            if string.hasSuffix("\n\n") || string.isEmpty {
                blockBoundary = true
                return
            }
            if string.hasSuffix("\n") {
                string.append("\n")
            } else {
                string.append("\n\n")
            }
            blockBoundary = true
        }

        func markBlockBoundary() {
            pendingInlineSpace = false
            if string.isEmpty || string.hasSuffix("\n\n") {
                blockBoundary = true
                return
            }
            if string.hasSuffix("\n") {
                string.append("\n")
            } else {
                string.append("\n\n")
            }
            blockBoundary = true
        }
    }

    // MARK: - Helpers

    private static func stripZeroWidth(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0xFEFF:
                return false
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func normalize(_ text: String) -> String {
        // Collapse runs of >2 newlines to exactly 2.
        var result = ""
        result.reserveCapacity(text.count)
        var consecutiveNewlines = 0
        for char in text {
            if char == "\n" {
                consecutiveNewlines += 1
                if consecutiveNewlines <= 2 {
                    result.append(char)
                }
            } else {
                consecutiveNewlines = 0
                result.append(char)
            }
        }
        // Trim leading/trailing whitespace and newlines.
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    /// Whitespace characters that should collapse to a single space.
    /// Excludes newlines so block-boundary logic stays explicit.
    var isWhitespaceForCollapse: Bool {
        if self == "\n" { return false }
        return self.isWhitespace
    }
}

private extension Element {
    /// SwiftSoup's `tagName()` may return capitalized values for SVG / XML
    /// elements; lowercasing once at the call site keeps comparisons cheap.
    func tagNameNormal() -> String {
        tagName().lowercased()
    }
}
