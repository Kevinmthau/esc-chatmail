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
/// `HTMLQuoteRemover.removeQuotes(from:mode:)` delegates here for the public
/// quote-removal path.
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
                try truncateTrailingContactSignature(in: document)
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

        if try truncateAtStrongHeaderBoundary(in: document) {
            return true
        }

        if try truncateAtHeaderTableBoundary(in: document) {
            return true
        }

        if try truncateAtHeaderBlockBoundary(in: document) {
            return true
        }

        if try truncateAtInlineHeaderBlockBoundary(in: document) {
            return true
        }

        return false
    }

    private static func truncateAtStrongHeaderBoundary(in document: Document) throws -> Bool {
        let strongElements = try document.select("strong")
        var fromElement: Element?

        for element in strongElements.array() {
            switch normalizedQuoteHeaderLabel((try? element.text()) ?? "") {
            case "from":
                if fromElement == nil {
                    fromElement = element
                }
            case "subject":
                guard let boundary = fromElement else { continue }
                try removeFromHereForward(quoteHeaderBoundaryElement(for: boundary))
                return true
            default:
                continue
            }
        }

        return false
    }

    private static func normalizedQuoteHeaderLabel(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "from:":
            return "from"
        case "subject:":
            return "subject"
        default:
            return ""
        }
    }

    private static let quoteHeaderBoundaryTags: Set<String> = [
        "div", "li", "p", "tr"
    ]

    private static func quoteHeaderBoundaryElement(for element: Element) -> Element {
        var current: Element? = element
        while let node = current {
            if node.tagNameNormal() == "body" {
                break
            }
            if quoteHeaderBoundaryTags.contains(node.tagNameNormal()) {
                return node
            }
            current = node.parent()
        }
        return element
    }

    private static let fromHeaderPrefixesLowercased: [String] = [
        "from:", "von:", "de:", "de :", "da:", "van:"
    ]

    private static let toHeaderPrefixesLowercased: [String] = [
        "to:", "an:", "à:", "à :", "para:", "aan:"
    ]

    private static let sentOrDateHeaderPrefixesLowercased: [String] = [
        "sent:", "date:", "gesendet:", "datum:", "envoyé:", "envoyé :", "enviado:", "inviato:", "verzonden:"
    ]

    private static let subjectHeaderPrefixesLowercased: [String] = [
        "subject:", "betreff:", "objet:", "objet :", "asunto:", "oggetto:", "assunto:", "onderwerp:"
    ]

    private struct HeaderTableBoundaryCandidate {
        let removalElement: Element
        let boundaryLineIndex: Int
        let tableDepth: Int
    }

    private static func truncateAtHeaderTableBoundary(in document: Document) throws -> Bool {
        guard let body = document.body() else { return false }
        let tables = try document.select("table").array()
        var candidates: [HeaderTableBoundaryCandidate] = []

        for table in tables {
            let precedingLines = visibleLineElements(in: body, includingEmpty: true, stoppingBefore: table)
            let tableLines = visibleLineElements(in: table, includingEmpty: true)
            let lines = precedingLines + tableLines
            let lineTexts = lines.map(\.text)

            guard let localStartIndex = tableLines.firstIndex(where: { isFromHeaderLine($0.text) }) else {
                continue
            }
            let startIndex = precedingLines.count + localStartIndex

            let boundary = quoteHeaderBoundaryMatch(before: startIndex, in: lines)

            let removalElement: Element
            let boundaryLineIndex: Int
            if let boundary {
                guard hasQuoteHeaderSequence(
                    startingAt: startIndex,
                    in: lineTexts,
                    requireSubject: boundary.kind == .contactSignature
                ) else {
                    continue
                }
                removalElement = boundary.kind == .hard ? lines[boundary.index].element : table
                boundaryLineIndex = boundary.kind == .hard ? boundary.index : startIndex
            } else {
                continue
            }

            candidates.append(HeaderTableBoundaryCandidate(
                removalElement: removalElement,
                boundaryLineIndex: boundaryLineIndex,
                tableDepth: tableDepth(table)
            ))
        }

        guard let candidate = candidates.min(by: { lhs, rhs in
            if lhs.boundaryLineIndex == rhs.boundaryLineIndex {
                return lhs.tableDepth > rhs.tableDepth
            }
            return lhs.boundaryLineIndex < rhs.boundaryLineIndex
        }) else {
            return false
        }

        try removeFromHereForward(candidate.removalElement)
        return true
    }

    private static func truncateAtHeaderBlockBoundary(in document: Document) throws -> Bool {
        guard let body = document.body() else { return false }
        let lines = visibleLineElements(in: body, includingEmpty: true)

        for index in lines.indices {
            guard isFromHeaderLine(lines[index].text) else {
                continue
            }

            guard let boundary = quoteHeaderBoundaryMatch(before: index, in: lines) else {
                continue
            }

            guard hasQuoteHeaderSequence(
                startingAt: index,
                in: lines,
                requireSubject: boundary.kind == .contactSignature
            ) else {
                continue
            }

            let removalElement = boundary.kind == .hard ? lines[boundary.index].element : lines[index].element
            try removeFromHereForward(removalElement)
            return true
        }

        return false
    }

    private static func truncateAtInlineHeaderBlockBoundary(in document: Document) throws -> Bool {
        guard let body = document.body() else { return false }

        for element in inlineHeaderBlockElements(in: body) {
            let lines = inlineHeaderLines(in: element)
            let lineTexts = lines.map(\.text)

            for index in lineTexts.indices {
                guard isFromHeaderLine(lineTexts[index]) else {
                    continue
                }

                let boundary = quoteHeaderBoundaryMatch(before: index, in: lineTexts)
                let requiresStrongInlineSignal = boundary == nil
                let requireSubject = boundary?.kind == .contactSignature || requiresStrongInlineSignal

                guard hasQuoteHeaderSequence(
                    startingAt: index,
                    in: lineTexts,
                    requireSubject: requireSubject
                ) else {
                    continue
                }

                if requiresStrongInlineSignal {
                    guard hasCurrentMessageContentBeforeInlineHeaderBlock(
                            startingAt: index,
                            in: lineTexts,
                            element: element,
                            body: body
                        ),
                        hasCompleteQuoteHeaderSequence(startingAt: index, in: lineTexts),
                        headerSequenceContainsEmailAddress(startingAt: index, in: lineTexts) else {
                        continue
                    }
                }

                let removalLineIndex = (boundary?.kind == .hard) ? (boundary?.index ?? index) : index
                guard let textNode = lines[removalLineIndex].startTextNode else {
                    try removeFromHereForward(element)
                    return true
                }

                try truncateAtTextNode(
                    textNode,
                    matchStartUTF16: lines[removalLineIndex].startUTF16Offset,
                    in: textNode.getWholeText()
                )
                return true
            }
        }

        return false
    }

    private enum QuoteHeaderBoundary {
        case hard
        case contactSignature
    }

    private struct QuoteHeaderBoundaryMatch {
        let kind: QuoteHeaderBoundary
        let index: Int
    }

    private static func quoteHeaderBoundaryMatch(
        before startIndex: Int,
        in lines: [VisibleLineElement]
    ) -> QuoteHeaderBoundaryMatch? {
        quoteHeaderBoundaryMatch(before: startIndex, in: lines.map(\.text))
    }

    private static func quoteHeaderBoundaryMatch(before startIndex: Int, in lineTexts: [String]) -> QuoteHeaderBoundaryMatch? {
        guard startIndex > 0 else { return nil }

        for candidate in stride(from: startIndex - 1, through: 0, by: -1) {
            let previousText = lineTexts[candidate]
            guard !previousText.isEmpty else { continue }

            if isTextualQuoteBoundaryLine(previousText) {
                return QuoteHeaderBoundaryMatch(kind: .hard, index: candidate)
            }

            if isContactSignatureLine(previousText) {
                return QuoteHeaderBoundaryMatch(kind: .contactSignature, index: candidate)
            }

            return nil
        }

        return nil
    }

    private static func isFromHeaderLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return fromHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) })
    }

    private static func isTextualQuoteBoundaryLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if lowercased.contains("begin forwarded message:") {
            return true
        }
        if lowercased.contains("forwarded message"), lowercased.contains("--") {
            return true
        }
        if lowercased.contains("original message"), lowercased.contains("--") {
            return true
        }
        return lowercased.trimmingCharacters(in: .whitespacesAndNewlines) == "________________________________"
    }

    private static func hasQuoteHeaderSequence(
        startingAt startIndex: Int,
        in lines: [VisibleLineElement],
        requireSubject: Bool = false
    ) -> Bool {
        hasQuoteHeaderSequence(
            startingAt: startIndex,
            in: lines.map(\.text),
            requireSubject: requireSubject
        )
    }

    private static func hasQuoteHeaderSequence(
        startingAt startIndex: Int,
        in lineTexts: [String],
        requireSubject: Bool = false
    ) -> Bool {
        var sawTo = false
        var sawSentOrDate = false
        var sawSubject = false
        let upperBound = min(lineTexts.count, startIndex + 24)

        guard startIndex + 1 < upperBound else { return false }

        for index in (startIndex + 1)..<upperBound {
            let lowercased = lineTexts[index].lowercased()
            if toHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                sawTo = true
            }
            if sentOrDateHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                sawSentOrDate = true
            }
            if subjectHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                sawSubject = true
            }

            if sawTo && (sawSentOrDate || sawSubject) {
                if !requireSubject || sawSubject {
                    return true
                }
            }
        }

        return false
    }

    private static func hasCompleteQuoteHeaderSequence(startingAt startIndex: Int, in lineTexts: [String]) -> Bool {
        var sawTo = false
        var sawSentOrDate = false
        var sawSubject = false
        let upperBound = min(lineTexts.count, startIndex + 24)

        guard startIndex + 1 < upperBound else { return false }

        for index in (startIndex + 1)..<upperBound {
            let lowercased = lineTexts[index].lowercased()
            if toHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                sawTo = true
            }
            if sentOrDateHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                sawSentOrDate = true
            }
            if subjectHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) {
                sawSubject = true
            }

            if sawTo && sawSentOrDate && sawSubject {
                return true
            }
        }

        return false
    }

    private static func headerSequenceContainsEmailAddress(startingAt startIndex: Int, in lineTexts: [String]) -> Bool {
        let upperBound = min(lineTexts.count, startIndex + 24)
        guard startIndex < upperBound else { return false }

        for index in startIndex..<upperBound {
            if containsEmailAddress(lineTexts[index]) {
                return true
            }
        }

        return false
    }

    private static func hasCurrentMessageContentBeforeInlineHeaderBlock(
        startingAt startIndex: Int,
        in lineTexts: [String],
        element: Element,
        body: Element
    ) -> Bool {
        if lineTexts.prefix(startIndex).contains(where: { !$0.isEmpty }) {
            return true
        }

        return hasVisibleTextBefore(element, in: body)
    }

    // MARK: - Text markers ("On … wrote:")

    /// Patterns matched against text-node content. Each text node is scanned
    /// for the earliest occurrence; if one is found, the containing element
    /// (and everything after it at every ancestor level) is removed.
    private static let textTruncationPatterns: [NSRegularExpression] = {
        let raw = [
            // English "On <date> <name> wrote:"
            "(?:^|[\\r\\n])\\s*On .{1,400}? wrote:",
            // iOS "On Jan 30, 2026 at 7:32 PM, Name"
            "(?:^|[\\r\\n])\\s*On [A-Z][a-z]+ \\d{1,2}, \\d{4} at \\d{1,2}:\\d{2}\\s*[AP]M,",
            // Outlook "-----Original Message-----"
            "(?:^|[\\r\\n])\\s*-{2,}\\s*Original Message\\s*-{2,}",
            // International "Le … a écrit:" / "Am … schrieb:"
            "(?:^|[\\r\\n])\\s*(?:Le|Am)\\s.{1,200}?\\s(?:a écrit|schrieb):"
        ]
        return raw.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    private static func truncateAtTextMarkers(in document: Document) throws {
        guard let body = document.body() else { return }
        let textNodes = collectTextNodes(rootElement: body)
        let candidates = [
            singleTextNodeMarkerCandidate(in: textNodes),
            inlineSplitTextMarkerCandidate(in: textNodes, body: body)
        ].compactMap { $0 }

        guard let candidate = candidates.min(by: { isEarlierTextMarkerCandidate($0, $1) }) else {
            return
        }

        try truncateAtTextNode(
            candidate.textNode,
            matchStartUTF16: candidate.matchStartUTF16,
            in: candidate.fullText
        )
    }

    private static func singleTextNodeMarkerCandidate(in textNodes: [TextNode]) -> TextMarkerCandidate? {
        for (index, textNode) in textNodes.enumerated() {
            let text = textNode.getWholeText()
            guard let match = earliestTextMarkerMatch(in: text) else { continue }
            return TextMarkerCandidate(
                textNode: textNode,
                matchStartUTF16: match.range.location,
                fullText: text,
                textNodeIndex: index
            )
        }
        return nil
    }

    private static func inlineSplitTextMarkerCandidate(in textNodes: [TextNode], body: Element) -> TextMarkerCandidate? {
        var textNodeIndexesByID: [ObjectIdentifier: Int] = [:]
        for (index, textNode) in textNodes.enumerated() {
            textNodeIndexesByID[ObjectIdentifier(textNode)] = index
        }

        let groups = groupedTextNodesByMarkerContainer(textNodes, body: body)
        var bestCandidate: TextMarkerCandidate?

        for group in groups {
            guard group.textNodes.count > 1 else { continue }
            let runs = textRuns(from: group)
            guard runs.count > 1 else { continue }

            let combinedText = runs.map { $0.text }.joined()
            guard let match = earliestTextMarkerMatch(in: combinedText),
                  let run = textRunForTruncation(atOrAfterUTF16Offset: match.range.location, in: runs),
                  let textNode = run.textNode,
                  let textNodeIndex = textNodeIndexesByID[ObjectIdentifier(textNode)] else {
                continue
            }

            let candidate = TextMarkerCandidate(
                textNode: textNode,
                matchStartUTF16: max(0, match.range.location - run.startUTF16Offset),
                fullText: run.text,
                textNodeIndex: textNodeIndex
            )
            if bestCandidate.map({ isEarlierTextMarkerCandidate(candidate, $0) }) ?? true {
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private static func earliestTextMarkerMatch(in text: String) -> NSTextCheckingResult? {
        let range = NSRange(location: 0, length: text.utf16.count)
        return textTruncationPatterns
            .compactMap { pattern in
                pattern.firstMatch(in: text, options: [], range: range)
            }
            .min { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }
    }

    private static func isEarlierTextMarkerCandidate(_ lhs: TextMarkerCandidate, _ rhs: TextMarkerCandidate) -> Bool {
        if lhs.textNodeIndex == rhs.textNodeIndex {
            return lhs.matchStartUTF16 < rhs.matchStartUTF16
        }
        return lhs.textNodeIndex < rhs.textNodeIndex
    }

    private struct TextNodeGroup {
        let container: Element
        var textNodes: [TextNode]
    }

    private struct TextMarkerCandidate {
        let textNode: TextNode
        let matchStartUTF16: Int
        let fullText: String
        let textNodeIndex: Int
    }

    private struct TextRun {
        let textNode: TextNode?
        let text: String
        let startUTF16Offset: Int

        var endUTF16Offset: Int {
            startUTF16Offset + text.utf16.count
        }
    }

    private static let textMarkerContainerTags: Set<String> = [
        "address", "article", "blockquote", "caption", "dd", "div", "dt",
        "footer", "header", "li", "main", "p", "pre", "section", "td", "th"
    ]

    private static func groupedTextNodesByMarkerContainer(
        _ textNodes: [TextNode],
        body: Element
    ) -> [TextNodeGroup] {
        var groups: [TextNodeGroup] = []
        var groupIndexesByContainer: [ObjectIdentifier: Int] = [:]

        for textNode in textNodes {
            guard let container = nearestTextMarkerContainer(for: textNode, body: body) else {
                continue
            }

            let id = ObjectIdentifier(container)
            if let index = groupIndexesByContainer[id] {
                groups[index].textNodes.append(textNode)
            } else {
                groupIndexesByContainer[id] = groups.count
                groups.append(TextNodeGroup(container: container, textNodes: [textNode]))
            }
        }

        return groups
    }

    private static func nearestTextMarkerContainer(for textNode: TextNode, body: Element) -> Element? {
        var current = textNode.parent() as? Element
        while let element = current {
            if element === body {
                return body
            }
            if textMarkerContainerTags.contains(element.tagNameNormal()) {
                return element
            }
            current = element.parent()
        }
        return nil
    }

    private static func textRuns(from group: TextNodeGroup) -> [TextRun] {
        var runs: [TextRun] = []
        var offset = 0
        let targetTextNodeIDs = Set(group.textNodes.map { ObjectIdentifier($0) })
        var hasSeenTargetTextNode = false
        var pendingLineBreakCount = 0

        func appendRun(textNode: TextNode?, text: String) {
            runs.append(TextRun(textNode: textNode, text: text, startUTF16Offset: offset))
            offset += text.utf16.count
        }

        func flushPendingLineBreaks() {
            guard pendingLineBreakCount > 0 else { return }
            appendRun(textNode: nil, text: String(repeating: "\n", count: pendingLineBreakCount))
            pendingLineBreakCount = 0
        }

        func walk(_ node: Node) {
            if let textNode = node as? TextNode {
                guard targetTextNodeIDs.contains(ObjectIdentifier(textNode)) else { return }
                let text = textNode.getWholeText()
                guard !text.isEmpty else { return }
                if hasSeenTargetTextNode {
                    flushPendingLineBreaks()
                }
                appendRun(textNode: textNode, text: text)
                hasSeenTargetTextNode = true
                return
            }

            guard let element = node as? Element else { return }
            if element.tagNameNormal() == "br" {
                if hasSeenTargetTextNode {
                    pendingLineBreakCount += 1
                }
                return
            }

            for child in element.getChildNodes() {
                walk(child)
            }
        }

        for child in group.container.getChildNodes() {
            walk(child)
        }

        return runs
    }

    private static func textRunForTruncation(atOrAfterUTF16Offset offset: Int, in runs: [TextRun]) -> TextRun? {
        if let containingTextRun = runs.first(where: { run in
            run.textNode != nil && offset >= run.startUTF16Offset && offset < run.endUTF16Offset
        }) {
            return containingTextRun
        }

        return runs.first { run in
            run.textNode != nil && run.startUTF16Offset > offset
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

        return "<div>\(preserved.map(escapedHTML).joined(separator: "<br>"))</div>"
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
                    try truncateAtTextNode(textNode, matchStartUTF16: match.range.location, in: text)
                    return
                }
            }
        }
    }

    private static let signatureEmailPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])
    }()

    private static let signatureURLPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\bhttps?://\\S+|\\bwww\\.[^\\s]+", options: [.caseInsensitive])
    }()

    private static let signaturePhonePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b\\+?\\d[\\d\\s().-]{6,}\\b", options: [])
    }()

    private static let signatureAddressPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?i)\b(?:street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|suite|ste|floor|fl)\b\.?"#,
            options: []
        )
    }()

    private static let signatureCityStateZipPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^[A-Z][A-Z .'-]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let signatureStandaloneContactLabelPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(m|c|o|f|d|t|p)[:.]?$", options: [.caseInsensitive])
    }()

    private static let signatureTitleKeywords: [String] = [
        "director", "manager", "vp", "vice president", "president", "founder",
        "ceo", "cfo", "cto", "coo", "realtor", "broker", "associate",
        "sales", "agent", "partner", "principal", "owner", "specialist"
    ]

    private static let signatureOrganizationKeywords: [String] = [
        " inc", " inc.", " llc", " ltd", " corp", " corp.", " corporation",
        " company", " co.", " partners", " group", " llp", " lp"
    ]

    private static let contactListIntroKeywords: [String] = [
        "contact", "email", "reviewer", "recipient"
    ]

    private static func truncateTrailingContactSignature(in document: Document) throws {
        guard let body = document.body() else { return }
        let lines = visibleLineElements(in: body, includingEmpty: true)
        guard let lastNonEmpty = lines.indices.last(where: { !lines[$0].text.isEmpty }) else { return }
        guard isContactSignatureLine(lines[lastNonEmpty].text) else { return }

        let scanStart = max(0, lastNonEmpty - 32)
        var contactLineCount = 0
        var signatureStart = lastNonEmpty
        var strongSupportLineCount = 0
        var signatureSupportLineCount = 0
        var nonEmailContactLineCount = 0
        var sawSignOffBeforeSignature = false
        var precedingBodyLine: String?
        var scanIndex = lastNonEmpty

        while scanIndex >= scanStart {
            let text = lines[scanIndex].text
            if text.isEmpty {
                guard let previousNonEmptyIndex = previousNonEmptyLineIndex(
                    before: scanIndex,
                    lowerBound: scanStart,
                    in: lines
                ) else {
                    break
                }

                let previousText = lines[previousNonEmptyIndex].text
                guard isContactSignatureLine(previousText) || isSignatureSupportLine(previousText) else {
                    precedingBodyLine = previousText
                    break
                }

                scanIndex = previousNonEmptyIndex
                continue
            }

            if isLikelySignOffLine(text) {
                sawSignOffBeforeSignature = true
                break
            }

            if isContactSignatureLine(text) {
                contactLineCount += 1
                if hasNonEmailContactSignal(text) {
                    nonEmailContactLineCount += 1
                }
                signatureStart = scanIndex
                scanIndex -= 1
                continue
            }

            guard isSignatureSupportLine(text) else {
                precedingBodyLine = text
                break
            }

            if isStrongSignatureSupportLine(text) {
                strongSupportLineCount += 1
            }
            signatureSupportLineCount += 1
            signatureStart = scanIndex
            scanIndex -= 1
        }

        guard contactLineCount >= 2 else { return }

        let nonEmptyRemovalCount = (signatureStart...lastNonEmpty).filter { !lines[$0].text.isEmpty }.count
        guard nonEmptyRemovalCount >= 3 else { return }
        if let precedingBodyLine, isContactListIntroLine(precedingBodyLine) {
            return
        }
        let hasStrongSignatureSignal = sawSignOffBeforeSignature || strongSupportLineCount > 0
        let hasWeakSinglePersonSignature = signatureSupportLineCount == 1 && nonEmailContactLineCount > 0
        guard hasStrongSignatureSignal || hasWeakSinglePersonSignature else {
            return
        }

        for index in signatureStart...lastNonEmpty {
            try lines[index].element.remove()
        }
    }

    private static func previousNonEmptyLineIndex(
        before index: Int,
        lowerBound: Int,
        in lines: [VisibleLineElement]
    ) -> Int? {
        guard index > lowerBound else { return nil }

        for candidate in stride(from: index - 1, through: lowerBound, by: -1) {
            if !lines[candidate].text.isEmpty {
                return candidate
            }
        }

        return nil
    }

    private static func isContactSignatureLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        if signatureEmailPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureURLPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signaturePhonePattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureAddressPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureCityStateZipPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureStandaloneContactLabelPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        return false
    }

    private static func hasNonEmailContactSignal(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        if signatureURLPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signaturePhonePattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureAddressPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureCityStateZipPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureStandaloneContactLabelPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        return false
    }

    private static func isSignatureSupportLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if isStrongSignatureSupportLine(text) {
            return true
        }
        if looksLikeSignatureNameSupportLine(text) {
            return true
        }
        return false
    }

    private static func isStrongSignatureSupportLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if signatureTitleKeywords.contains(where: { lowercased.contains($0) }) {
            return true
        }
        if signatureOrganizationKeywords.contains(where: { lowercased.contains($0) }) {
            return true
        }
        return false
    }

    private static func isContactListIntroLine(_ text: String) -> Bool {
        let lowercased = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return lowercased.hasSuffix(":") &&
            contactListIntroKeywords.contains(where: { lowercased.contains($0) })
    }

    private static func looksLikeSignatureNameSupportLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeNameLine(trimmed) else { return false }

        let sentencePunctuation = CharacterSet(charactersIn: ".,:;!?")
        guard trimmed.rangeOfCharacter(from: sentencePunctuation) == nil else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in
            guard let firstLetter = word.first(where: { $0.isLetter }) else { return false }
            return firstLetter.isUppercase
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

    private struct VisibleLineElement {
        let element: Element
        let text: String
    }

    private struct InlineHeaderLine {
        let text: String
        let startTextNode: TextNode?
        let startUTF16Offset: Int
    }

    private static let visibleLineElementTags: Set<String> = [
        "div", "li", "p", "tr"
    ]

    private static let inlineHeaderBlockElementTags: Set<String> = [
        "div", "p", "td", "th"
    ]

    private static func visibleLineElements(
        in rootElement: Element,
        includingEmpty: Bool,
        stoppingBefore target: Element? = nil
    ) -> [VisibleLineElement] {
        var result: [VisibleLineElement] = []
        var reachedTarget = false

        func walk(_ node: Node) {
            guard !reachedTarget else { return }
            guard let element = node as? Element else { return }
            if let target, element === target {
                reachedTarget = true
                return
            }
            guard !isHiddenFromVisibleText(element) else { return }
            let tag = element.tagNameNormal()
            if visibleLineElementTags.contains(tag),
               !hasDescendantVisibleLineElement(element),
               !elementContainsDescendantTable(element) {
                let text = normalizedVisibleLineText(element)
                if includingEmpty || !text.isEmpty {
                    result.append(VisibleLineElement(element: element, text: text))
                }
                return
            }

            for child in element.getChildNodes() {
                walk(child)
            }
        }

        walk(rootElement)
        return result
    }

    private static func inlineHeaderBlockElements(in rootElement: Element) -> [Element] {
        var result: [Element] = []

        func walk(_ node: Node) {
            guard let element = node as? Element else { return }
            guard !isHiddenFromVisibleText(element) else { return }
            let tag = element.tagNameNormal()
            if inlineHeaderBlockElementTags.contains(tag),
               elementContainsBR(element),
               !hasDescendantInlineHeaderBlockElement(element) {
                result.append(element)
                return
            }

            for child in element.getChildNodes() {
                walk(child)
            }
        }

        walk(rootElement)
        return result
    }

    private static func inlineHeaderLines(in element: Element) -> [InlineHeaderLine] {
        var result: [InlineHeaderLine] = []
        var currentText = ""
        var currentStartTextNode: TextNode?
        var currentStartUTF16Offset = 0

        func appendText(_ rawText: String, from textNode: TextNode) {
            let normalized = rawText.replacingOccurrences(of: "\u{00a0}", with: " ")
            guard let firstTextIndex = normalized.firstIndex(where: { !$0.isWhitespace }) else {
                return
            }

            if currentStartTextNode == nil {
                currentStartTextNode = textNode
                currentStartUTF16Offset = normalized[..<firstTextIndex].utf16.count
            }

            let collapsed = normalizedVisibleLineText(normalized)
            guard !collapsed.isEmpty else { return }

            if !currentText.isEmpty, !currentText.hasSuffix(" ") {
                currentText.append(" ")
            }
            currentText.append(collapsed)
        }

        func finishLine() {
            result.append(InlineHeaderLine(
                text: normalizedVisibleLineText(currentText),
                startTextNode: currentStartTextNode,
                startUTF16Offset: currentStartUTF16Offset
            ))
            currentText = ""
            currentStartTextNode = nil
            currentStartUTF16Offset = 0
        }

        func walk(_ node: Node) {
            if let textNode = node as? TextNode {
                appendText(textNode.getWholeText(), from: textNode)
                return
            }

            guard let element = node as? Element else { return }
            guard !isHiddenFromVisibleText(element) else { return }
            if element.tagNameNormal() == "br" {
                finishLine()
                return
            }

            for child in element.getChildNodes() {
                walk(child)
            }
        }

        for child in element.getChildNodes() {
            walk(child)
        }

        finishLine()
        return result
    }

    private static func hasDescendantVisibleLineElement(_ element: Element) -> Bool {
        for child in element.getChildNodes() {
            guard let childElement = child as? Element else { continue }
            guard !isHiddenFromVisibleText(childElement) else { continue }
            if visibleLineElementTags.contains(childElement.tagNameNormal()) {
                return true
            }
            if hasDescendantVisibleLineElement(childElement) {
                return true
            }
        }
        return false
    }

    private static func hasDescendantInlineHeaderBlockElement(_ element: Element) -> Bool {
        for child in element.getChildNodes() {
            guard let childElement = child as? Element else { continue }
            guard !isHiddenFromVisibleText(childElement) else { continue }
            if inlineHeaderBlockElementTags.contains(childElement.tagNameNormal()),
               elementContainsBR(childElement) {
                return true
            }
            if hasDescendantInlineHeaderBlockElement(childElement) {
                return true
            }
        }
        return false
    }

    private static func elementContainsBR(_ element: Element) -> Bool {
        for child in element.getChildNodes() {
            guard let childElement = child as? Element else { continue }
            guard !isHiddenFromVisibleText(childElement) else { continue }
            if childElement.tagNameNormal() == "br" {
                return true
            }
            if elementContainsBR(childElement) {
                return true
            }
        }
        return false
    }

    private static func elementContainsDescendantTable(_ element: Element) -> Bool {
        for child in element.getChildNodes() {
            guard let childElement = child as? Element else { continue }
            guard !isHiddenFromVisibleText(childElement) else { continue }
            if childElement.tagNameNormal() == "table" {
                return true
            }
            if elementContainsDescendantTable(childElement) {
                return true
            }
        }
        return false
    }

    private static func tableDepth(_ table: Element) -> Int {
        var depth = 0
        var current = table.parent()
        while let node = current {
            if node.tagNameNormal() == "body" {
                break
            }
            depth += 1
            current = node.parent()
        }
        return depth
    }

    private static func containsEmailAddress(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return signatureEmailPattern?.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func hasVisibleTextBefore(_ target: Element, in rootElement: Element) -> Bool {
        var reachedTarget = false
        var sawText = false

        func walk(_ node: Node) {
            guard !reachedTarget, !sawText else { return }

            if let element = node as? Element {
                if element === target {
                    reachedTarget = true
                    return
                }
                guard !isHiddenFromVisibleText(element) else { return }
            }

            if let textNode = node as? TextNode,
               !normalizedVisibleLineText(textNode.getWholeText()).isEmpty {
                sawText = true
                return
            }

            for child in node.getChildNodes() {
                walk(child)
            }
        }

        walk(rootElement)
        return sawText
    }

    private static func isHiddenFromVisibleText(_ element: Element) -> Bool {
        if element.hasAttr("hidden") {
            return true
        }

        let style = ((try? element.attr("style")) ?? "")
            .lowercased()
            .filter { !$0.isWhitespace }
        return style.contains("display:none") ||
            style.contains("visibility:hidden")
    }

    private static func normalizedVisibleLineText(_ element: Element) -> String {
        let text = (try? element.text()) ?? ""
        return normalizedVisibleLineText(text)
    }

    private static func normalizedVisibleLineText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates the document at the given text node and offset:
    /// - text before `matchStart` in the text node is preserved
    /// - text from `matchStart` forward is removed
    /// - any sibling of the text node that appears after it in the same parent is removed
    /// - at every ancestor up to (but not including) `<body>`, all siblings
    ///   appearing after the ancestor are removed; the ancestor itself is kept
    ///   because it may contain preserved-prefix content above the match.
    private static func truncateAtTextNode(_ textNode: TextNode, matchStartUTF16: Int, in fullText: String) throws {
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
        let text = fullText
        let prefixEndIndex = stringIndex(in: text, utf16Offset: matchStartUTF16)
        let prefix = String(text[..<prefixEndIndex])
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try textNode.remove()
        } else {
            let newText = TextNode(prefix, textNode.getBaseUri())
            try textNode.replaceWith(newText)
        }
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index {
        let safeOffset = max(0, min(utf16Offset, text.utf16.count))
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: safeOffset)
        return String.Index(utf16Index, within: text) ?? text.endIndex
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

}
