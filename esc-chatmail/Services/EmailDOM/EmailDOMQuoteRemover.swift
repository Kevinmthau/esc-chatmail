import Foundation
import SwiftSoup

/// DOM-based replacement for `HTMLQuoteRemover`.
///
/// Walks the document and removes:
/// 1. Provider-specific quote containers (gmail_quote, blockquote[type=cite],
///    AppleMailSignature, OutlookMessageHeader, moz-cite-prefix, etc.) by
///    CSS selector — no nested-div counting needed because SwiftSoup tracks
///    the tree structure.
/// 2. Structural quote boundaries (Outlook reference container,
///    border-top header tables) by truncating subsequent siblings.
/// 3. Text-based quote markers ("On … wrote:", "-----Original Message-----")
///    by finding the text node and removing the node and all subsequent
///    siblings at every ancestor level.
/// 4. (Optional, mode = .quotedAndSignatures) Signature wrappers
///    (gmail_signature, ms-outlook-signature) and footer/unsubscribe
///    sections.
///
/// API parity with `HTMLQuoteRemover.removeQuotes(from:mode:)` is the goal.
/// When parity is reached behind the feature flag, this becomes the default.
enum EmailDOMQuoteRemover {

    typealias RemovalMode = HTMLQuoteRemover.RemovalMode

    /// Mirror of `HTMLQuoteRemover.removeQuotes(from:mode:)` using the DOM.
    /// Returns `nil` for `nil` input, mirroring the legacy contract.
    /// On parser failure or any internal error, falls back to the input
    /// unchanged rather than returning nil — callers depend on a String result
    /// being a meaningful representation.
    static func removeQuotes(from html: String?, mode: RemovalMode = .quotedAndSignatures) -> String? {
        guard let html else { return nil }

        // Match legacy contract: if the input was a fragment (no document
        // structure), emit a fragment by returning body's inner HTML. Otherwise
        // emit the full document. Compose-time reply quoting depends on this —
        // wrapping a fragment with `<html><body>` would corrupt outgoing MIME
        // parts.
        let inputIsFragment = !hasDocumentWrapper(html)
        guard let document = try? EmailDOMFragmentParser.parse(
            html,
            inputIsFragment: inputIsFragment
        ) else {
            return html
        }
        document.outputSettings().prettyPrint(pretty: false)

        do {
            try removeQuotedContainers(in: document)
            let didTruncateAtStructuralBoundary = try truncateAtStructuralBoundaries(in: document)
            if !didTruncateAtStructuralBoundary {
                try truncateAtTextMarkers(in: document)
            }
            if mode == .quotedAndSignatures {
                try removeSignatureWrappers(in: document)
                try removeFooterContainers(in: document)
                try truncateAtSignatureMarkers(in: document)
            }
            if inputIsFragment, let body = document.body() {
                return try body.html()
            }
            return try document.outerHtml()
        } catch {
            // SwiftSoup throws on misuse, not on malformed HTML. If we land
            // here something is broken in the selector strings; degrade
            // gracefully.
            return html
        }
    }

    private static func hasDocumentWrapper(_ html: String) -> Bool {
        containsTagPrefix("<!doctype", in: html) ||
            containsTagPrefix("<html", in: html) ||
            containsTagPrefix("<head", in: html) ||
            containsTagPrefix("<body", in: html)
    }

    private static func containsTagPrefix(_ prefix: String, in html: String) -> Bool {
        var searchStart = html.startIndex

        while let range = html.range(
            of: prefix,
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            let boundaryIndex = range.upperBound
            if boundaryIndex == html.endIndex || !isTagNameCharacter(html[boundaryIndex]) {
                return true
            }
            searchStart = boundaryIndex
        }

        return false
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_"
    }

    // MARK: - Containers (provider-specific)

    /// CSS selectors for elements whose entire subtree should be removed
    /// because they are the quoted history.
    private static let quotedContainerSelectors: [String] = [
        // Gmail
        "div.gmail_quote",
        "div.gmail_attr",
        // Apple Mail
        "blockquote[type=cite]",
        "div.AppleMailSignature",
        // Mozilla / Thunderbird
        "div.moz-cite-prefix",
        // Outlook desktop
        "div.OutlookMessageHeader",
        // Generic
        "blockquote",
        // HTML comment markers handled separately because SwiftSoup represents
        // them as Comment nodes, not Elements.
    ]

    private static func removeQuotedContainers(in document: Document) throws {
        // border-left styled divs are commonly used as quote blocks; match by
        // attribute value substring rather than encoded inline style strings.
        let borderLeftDivs = try document.select("div[style*=border-left]")
        for element in borderLeftDivs.array() {
            try element.remove()
        }

        for selector in quotedContainerSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                try element.remove()
            }
        }

        // Remove `<!-- originalMessage --> … <!-- /originalMessage -->` pairs.
        removeCommentDelimitedRegions(in: document, openHint: "originalmessage", closeHint: "/originalmessage")
    }

    // MARK: - Structural boundaries (truncate from this node onward)

    private static let structuralQuoteSelectors: [String] = [
        // Outlook reference container, id may be prefixed (x_mail-editor-…)
        "[id*=mail-editor-reference-message-container]"
    ]

    private static func truncateAtStructuralBoundaries(in document: Document) throws -> Bool {
        for selector in structuralQuoteSelectors {
            let elements = try document.select(selector)
            if let first = elements.first() {
                try removeFromHereForward(first)
                return true
            }
        }

        // Outlook desktop border-top gray header block with From/Sent/To/Subject inside.
        // SwiftSoup parses the inline style attribute as a string; do a coarse
        // substring match so we don't need a CSS engine for `border-top: solid #E1E1E1`.
        let candidates = try document.select("div[style]")
        for element in candidates.array() {
            let style = (try? element.attr("style")) ?? ""
            guard style.range(of: "border-top", options: .caseInsensitive) != nil,
                  style.range(of: "#E1E1E1", options: .caseInsensitive) != nil else { continue }
            let text = (try? element.text()) ?? ""
            let lower = text.lowercased()
            guard lower.contains("from:"),
                  lower.contains("subject:"),
                  lower.contains("to:") else { continue }
            try removeFromHereForward(element)
            return true
        }

        return false
    }

    // MARK: - Text markers ("On … wrote:")

    /// Patterns matched against text-node content. Each text node is scanned
    /// for the earliest occurrence; if one is found, the containing element
    /// (and everything after it at every ancestor level) is removed.
    private static let textTruncationPatterns: [NSRegularExpression] = {
        let raw = [
            // English "On <date> <name> wrote:"
            "\\bOn .{1,400}? wrote:",
            // iOS "On Jan 30, 2026 at 7:32 PM, Name"
            "\\bOn [A-Z][a-z]+ \\d{1,2}, \\d{4} at \\d{1,2}:\\d{2}\\s*[AP]M,",
            // Outlook "-----Original Message-----"
            "-{2,}\\s*Original Message\\s*-{2,}",
            // International "Le … a écrit:" / "Am … schrieb:"
            "\\b(?:Le|Am)\\s.{1,200}?\\s(?:a écrit|schrieb):"
        ]
        return raw.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    private static func truncateAtTextMarkers(in document: Document) throws {
        guard let body = document.body() else { return }
        let textNodes = collectTextNodes(rootElement: body)
        for textNode in textNodes {
            let text = textNode.text()
            for pattern in textTruncationPatterns {
                let range = NSRange(location: 0, length: text.utf16.count)
                if let match = pattern.firstMatch(in: text, options: [], range: range) {
                    try truncateAtTextNode(textNode, matchStart: match.range.location, in: text)
                    return
                }
            }
        }
    }

    // MARK: - Signature wrappers

    private static let signatureWrapperSelectors: [String] = [
        "div.gmail_signature",
        "div.gmail_signature_prefix",
        "div[data-smartmail=gmail_signature]",
        "div[id*=ms-outlook-mobile-signature]",
        "div[class*=ms-outlook-mobile-signature]",
        "div.ms-outlook-signature",
        "div[id=Signature]",
        "div.signature",
        "div[class*=moz-signature]"
    ]

    private static func removeSignatureWrappers(in document: Document) throws {
        for selector in signatureWrapperSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                let replacement = preservedSignOffHTML(fromSignatureElement: element)
                if replacement.isEmpty {
                    try element.remove()
                } else {
                    try element.before(replacement)
                    try element.remove()
                }
            }
        }
    }

    private static func preservedSignOffHTML(fromSignatureElement element: Element) -> String {
        var lines = EmailDOMTextExtractor.paragraphAwareText(from: element)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.first == "--" {
            lines.removeFirst()
        }

        guard !lines.isEmpty else { return "" }

        if isLikelyCombinedSignOffAndNameLine(lines[0]) {
            return "<div>\(escapedHTML(lines[0]))</div>"
        }

        guard isLikelySignOffLine(lines[0]) else { return "" }

        var preserved = [lines[0]]
        if lines.count > 1, looksLikeNameLine(lines[1]) {
            preserved.append(lines[1])
        }

        return preserved
            .map { "<div>\(escapedHTML($0))</div>" }
            .joined()
    }

    private static func isLikelySignOffLine(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        return signOffPhrases.contains(normalized)
    }

    private static func isLikelyCombinedSignOffAndNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 60 else { return false }

        let lowercased = trimmed.lowercased()
        for signOff in signOffPhrasesForPrefixMatching {
            for separator in [",", " "] {
                let prefix = signOff + separator
                guard lowercased.hasPrefix(prefix) else { continue }
                let remainder = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return looksLikeNameLine(remainder)
            }
        }

        return false
    }

    private static func looksLikeNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }

        let lowercased = trimmed.lowercased()
        let disallowedFragments = ["@", "http", "www.", "|", "tel:", "fax", "mobile", "office", "cell", "phone"]
        guard !disallowedFragments.contains(where: { lowercased.contains($0) }) else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count) else { return false }

        return true
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Footer containers (newsletter unsubscribe, social icons)

    private static let footerSelectors: [String] = [
        "div[class*=footer]",
        "table[class*=footer]",
        "div[id*=footer]",
        "table[class*=social]",
        "div[class*=social]",
        "div[class*=unsubscribe]",
        "p[class*=unsubscribe]",
        "div[class*=sig]",
        "table[class*=signature]"
    ]

    private static func removeFooterContainers(in document: Document) throws {
        for selector in footerSelectors {
            let elements = try document.select(selector)
            for element in elements.array() {
                try element.remove()
            }
        }
    }

    // MARK: - Signature text markers

    private static let signatureTextMarkers: [NSRegularExpression] = {
        let raw = [
            "^\\s*--\\s*$",                  // line containing only --
            "Sent from my (?:iPhone|iPad|Android|Galaxy|Pixel|Samsung)",
            "Sent from (?:Outlook|Mail for Windows|Spark|ProtonMail|BlueMail|Gmail|Yahoo Mail)",
            "Get Outlook for",
            "This email is confidential",
            "This e-mail is meant for only the intended recipient",
            "Notice To Recipient:",
            "If you are not the intended recipient",
            "\\*Wire Fraud",
            "Wire Fraud is Real",
            "Before wiring any money"
        ]
        return raw.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    private static let signOffPhrases: Set<String> = [
        "all the best",
        "best",
        "best regards",
        "best wishes",
        "cheers",
        "kind regards",
        "many thanks",
        "regards",
        "sincerely",
        "thank you",
        "thanks",
        "warm regards",
        "warmly",
        "yours truly"
    ]

    private static let signOffPhrasesForPrefixMatching: [String] = signOffPhrases.sorted {
        if $0.count == $1.count {
            return $0 < $1
        }
        return $0.count > $1.count
    }

    private static func truncateAtSignatureMarkers(in document: Document) throws {
        guard let body = document.body() else { return }
        let textNodes = collectTextNodes(rootElement: body)
        for textNode in textNodes {
            let text = textNode.text()
            for pattern in signatureTextMarkers {
                let range = NSRange(location: 0, length: text.utf16.count)
                if let match = pattern.firstMatch(in: text, options: [], range: range) {
                    try truncateAtTextNode(textNode, matchStart: match.range.location, in: text)
                    return
                }
            }
        }
    }

    // MARK: - Tree surgery

    private static func collectTextNodes(rootElement: Element) -> [TextNode] {
        var result: [TextNode] = []
        var stack: [Node] = [rootElement]
        while let node = stack.popLast() {
            if let textNode = node as? TextNode {
                let trimmed = textNode.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(textNode)
                }
            } else {
                // Children must be visited in document order; append in reverse
                // so popLast yields the leftmost child next.
                let children = node.getChildNodes()
                for child in children.reversed() {
                    stack.append(child)
                }
            }
        }
        return result
    }

    /// Truncates the document at the given text node and offset:
    /// - text before `matchStart` in the text node is preserved
    /// - text from `matchStart` forward is removed
    /// - any sibling of the text node that appears after it in the same parent is removed
    /// - at every ancestor up to (but not including) `<body>`, all siblings
    ///   appearing after the ancestor are removed; the ancestor itself is kept
    ///   because it may contain preserved-prefix content above the match.
    private static func truncateAtTextNode(_ textNode: TextNode, matchStart: Int, in fullText: String) throws {
        // Remove siblings AFTER textNode at its level.
        try removeAllSiblingsAfter(textNode)

        // Walk up and remove siblings after each ancestor (but keep the ancestor itself).
        var current: Element? = textNode.parent() as? Element
        while let node = current {
            if node.tagNameNormal() == "body" { break }
            try removeAllSiblingsAfter(node)
            current = node.parent()
        }

        // Trim or remove the text node based on whether a meaningful prefix exists.
        let text = textNode.text()
        let safeStart = max(0, min(matchStart, text.count))
        let prefixEndIndex = text.index(text.startIndex, offsetBy: safeStart, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = String(text[..<prefixEndIndex])
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try textNode.remove()
        } else {
            let newText = TextNode(prefix, textNode.getBaseUri())
            try textNode.replaceWith(newText)
        }
    }

    /// Removes the given element and every node that appears after it in
    /// document order, up to (but not including) `<body>`.
    private static func removeFromHereForward(_ element: Element) throws {
        // First, remove later siblings at this level.
        try removeAllSiblingsAfter(element)

        // Walk up: at each ancestor (but not body), remove its later siblings.
        // Keep the ancestor itself because earlier-in-document content above
        // our target lives inside the ancestor chain.
        var current: Element? = element.parent()
        while let node = current {
            if node.tagNameNormal() == "body" { break }
            try removeAllSiblingsAfter(node)
            current = node.parent()
        }

        // Finally remove the element itself (parent links are still valid because
        // we only removed siblings, never ancestors).
        try element.remove()
    }

    private static func removeAllSiblingsAfter(_ node: Node) throws {
        guard let parent = node.parent() as? Element else { return }
        var found = false
        let children = parent.getChildNodes()
        for child in children {
            if found {
                try child.remove()
                continue
            }
            if child === node {
                found = true
            }
        }
    }

    // MARK: - Comment-delimited regions

    /// Removes everything between `<!-- openHint -->` and `<!-- closeHint -->`
    /// inclusive. SwiftSoup represents these as `Comment` nodes; selectors
    /// don't reach them, so we walk the comment list directly.
    private static func removeCommentDelimitedRegions(in document: Document, openHint: String, closeHint: String) {
        guard let body = document.body() else { return }
        var openComment: Comment?
        var closeComment: Comment?
        let openMatch = openHint.lowercased()
        let closeMatch = closeHint.lowercased()
        walkAllComments(in: body) { comment in
            let data = comment.getData().lowercased()
            if openComment == nil, data.contains(openMatch) {
                openComment = comment
            } else if openComment != nil, closeComment == nil, data.contains(closeMatch) {
                closeComment = comment
            }
        }
        guard let open = openComment, let close = closeComment else { return }
        // Best-effort: if open and close share a parent, remove nodes between.
        // Otherwise just remove the two comments and let other passes handle the body.
        let openParent = open.parent() as? Element
        let closeParent = close.parent() as? Element
        if let parent = openParent, parent === closeParent {
            let children = parent.getChildNodes()
            var inside = false
            for child in children {
                if !inside {
                    if child === open {
                        inside = true
                    }
                    continue
                }
                if child === close {
                    try? child.remove()
                    inside = false
                    continue
                }
                try? child.remove()
            }
            try? open.remove()
            return
        }
        try? open.remove()
        try? close.remove()
    }

    private static func walkAllComments(in node: Node, visit: (Comment) -> Void) {
        if let comment = node as? Comment {
            visit(comment)
        }
        for child in node.getChildNodes() {
            walkAllComments(in: child, visit: visit)
        }
    }
}

private extension Element {
    func tagNameNormal() -> String {
        tagName().lowercased()
    }
}
