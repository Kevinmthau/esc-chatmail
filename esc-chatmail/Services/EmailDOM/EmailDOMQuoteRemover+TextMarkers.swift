import Foundation
import SwiftSoup

// MARK: - Text markers ("On … wrote:")
//
// Truncates the body at an inline quote-attribution line — "On <date> … wrote:",
// "-----Original Message-----", "Le … a écrit:", "Am … schrieb:" — that marks the
// start of quoted history but isn't wrapped in a provider container. The marker
// can sit inside a single text node or be split across <br>-separated inline runs,
// so both shapes are scanned and the earliest match wins. Builds on the
// tree-surgery layer (collectTextNodes, truncateAtTextNode).
extension EmailDOMQuoteRemover {

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

    static func truncateAtTextMarkers(in document: Document) throws {
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
}
