import Foundation
import SwiftSoup

// MARK: - Tree surgery
//
// The shared DOM leaf-helper layer every quote/signature pass builds on:
// collecting non-empty text nodes, projecting elements into "visible lines",
// and the node-removal primitives (truncate-at-text-node, remove-from-here-
// forward, remove-siblings-after). These helpers are deliberately generic —
// they carry no quote- or signature-specific knowledge — so the structural-
// boundary, text-marker, and signature passes in the sibling files all build
// on them. Keeping them in one place lets those passes be split out without
// re-duplicating the surgery.
extension EmailDOMQuoteRemover {

    static func collectTextNodes(rootElement: Element) -> [TextNode] {
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

    struct VisibleLineElement {
        let element: Element
        let text: String
    }

    struct InlineHeaderLine {
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

    static func visibleLineElements(
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

    static func inlineHeaderBlockElements(in rootElement: Element) -> [Element] {
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

    static func inlineHeaderLines(in element: Element) -> [InlineHeaderLine] {
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

    static func tableDepth(_ table: Element) -> Int {
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

    static func hasVisibleTextBefore(_ target: Element, in rootElement: Element) -> Bool {
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
    static func truncateAtTextNode(_ textNode: TextNode, matchStartUTF16: Int, in fullText: String) throws {
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
    static func removeFromHereForward(_ element: Element) throws {
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
