import Foundation
import SwiftSoup

// MARK: - Structural boundaries (truncate from this node onward)
//
// Detects quoted-history boundaries that are structural rather than wrapped in a
// provider container: the Outlook reference container, border-top gray header
// blocks, bold From:/Subject: headers, and From/Sent/To/Subject header
// sequences rendered as tables, block lines, or <br>-split inline runs. When a
// boundary is found, everything from it forward is removed. Builds on the
// tree-surgery layer (visibleLineElements, inlineHeader*, removeFromHereForward,
// truncateAtTextNode) and borrows isContactSignatureLine / containsEmailAddress
// from the signature pass to disambiguate weak header sequences.
extension EmailDOMQuoteRemover {

    private static let structuralQuoteSelectors: [String] = [
        // Outlook reference container, id may be prefixed (x_mail-editor-…)
        "[id*=mail-editor-reference-message-container]"
    ]

    static func truncateAtStructuralBoundaries(in document: Document) throws -> Bool {
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
}
