import Foundation
import SwiftSoup

struct EmailDocumentRenderQualityMetrics: Equatable, Sendable {
    let imageCount: Int
    let tableCount: Int
    let linkCount: Int
    let semanticElementCount: Int
    let elementCount: Int
    let largeSpacerSignalCount: Int
    let hiddenPrimaryContentCount: Int
    let footerLineRatio: Double

    static let empty = Self(
        imageCount: 0,
        tableCount: 0,
        linkCount: 0,
        semanticElementCount: 0,
        elementCount: 0,
        largeSpacerSignalCount: 0,
        hiddenPrimaryContentCount: 0,
        footerLineRatio: 0
    )
}

struct EmailDocumentHTMLMetrics: Equatable, Sendable {
    let imageCount: Int
    let tableCount: Int
    let linkCount: Int

    init(imageCount: Int, tableCount: Int, linkCount: Int) {
        self.imageCount = imageCount
        self.tableCount = tableCount
        self.linkCount = linkCount
    }

    init(classificationHTML html: String) {
        let lowercasedHTML = html.lowercased()
        self.imageCount = Self.countOccurrences(of: "<img", in: lowercasedHTML)
        self.tableCount = Self.countOccurrences(of: "<table", in: lowercasedHTML)
        self.linkCount = Self.countOccurrences(of: "<a ", in: lowercasedHTML)
    }

    private static func countOccurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return text.components(separatedBy: token).count - 1
    }
}

/// A parsed HTML email document with DOM-based operations.
///
/// `EmailDocument` is the canonical DOM representation used by the HTML
/// processing pipeline. It wraps `SwiftSoup.Document` behind a Swift-native API
/// so callers do not need to import SwiftSoup directly and so call sites read
/// declaratively instead of as regex string surgery.
///
/// Design notes:
/// - `EmailDocument` is a reference type because `SwiftSoup.Document` is a
///   class with shared identity. Mutations modify the underlying DOM in place.
/// - The type is not `Sendable`. Each caller should parse, mutate, and emit
///   within a single isolation domain. Producing a new `EmailDocument` is
///   cheap relative to the cost of recomputing email rendering.
/// - All operations are graceful on malformed HTML: SwiftSoup's parser is
///   lenient and produces a best-effort DOM rather than throwing.
final class EmailDocument {
    fileprivate let document: SwiftSoup.Document

    fileprivate init(document: SwiftSoup.Document) {
        self.document = document
    }

    // MARK: - Parsing

    /// Parses an HTML fragment or document into an `EmailDocument`.
    /// Returns `nil` if the input is `nil`. Throws only on catastrophic
    /// SwiftSoup parser failure; SwiftSoup normally returns a best-effort DOM
    /// even for malformed HTML.
    static func parse(_ html: String?) throws -> EmailDocument? {
        guard let html else { return nil }
        let document = try SwiftSoup.parse(html)
        // Disable pretty-printing so emitted HTML stays close to the input for
        // whitespace-sensitive callers and tests.
        document.outputSettings().prettyPrint(pretty: false)
        return EmailDocument(document: document)
    }

    /// Convenience: parses HTML, returning nil on any failure (including throws).
    /// Use this at boundaries where graceful degradation is wanted.
    static func tryParse(_ html: String?) -> EmailDocument? {
        guard let html else { return nil }
        do {
            return try parse(html)
        } catch {
            return nil
        }
    }

    // MARK: - HTML output

    /// Renders the full document HTML (including `<html><head><body>` wrappers
    /// that SwiftSoup may have synthesized).
    func outerHTML() -> String {
        (try? document.outerHtml()) ?? ""
    }

    /// Renders just the body's inner HTML. Use this when the caller passed in
    /// a fragment (no `<html>` wrapper) and wants a fragment back.
    func bodyInnerHTML() -> String {
        guard let body = document.body() else {
            return outerHTML()
        }
        return (try? body.html()) ?? ""
    }

    // MARK: - Plain text

    /// Returns plain text extracted from the document. SwiftSoup handles
    /// `<br>`, block elements, list items and whitespace collapsing.
    /// If `preserveParagraphs` is true, block-level boundaries are emitted as
    /// `\n\n`; otherwise SwiftSoup's default single-space joining is used.
    /// `divsAsLineBreaks` keeps Gmail-style line-per-div HTML compatible with
    /// downstream email line unwrapping.
    func plainText(preserveParagraphs: Bool = true, divsAsLineBreaks: Bool = false) -> String {
        guard preserveParagraphs else {
            return (try? document.text()) ?? ""
        }
        return EmailDOMTextExtractor.paragraphAwareText(
            from: document,
            divsAsLineBreaks: divsAsLineBreaks
        )
    }

    // MARK: - Inline content IDs

    /// Returns the set of `cid:` references found in image/link attributes and
    /// raw inline HTML, normalized to lowercase identifiers without the `cid:`
    /// prefix.
    func referencedInlineContentIDs() -> Set<String> {
        var result = Set<String>()
        let attributes = ["src", "background", "href", "xlink:href"]
        for attribute in attributes {
            let elements = (try? document.select("[\(attribute)]")) ?? Elements()
            for element in elements.array() {
                let value = (try? element.attr(attribute)) ?? ""
                guard !value.isEmpty,
                      let cid = Self.cidIdentifier(from: value) else {
                    continue
                }
                result.insert(cid)
            }
        }
        let srcsetElements = (try? document.select("[srcset]")) ?? Elements()
        for element in srcsetElements.array() {
            let value = (try? element.attr("srcset")) ?? ""
            result.formUnion(Self.cidIdentifiers(inSrcset: value))
        }

        // Also search inline style="...url(cid:...)" patterns. Doing this once
        // against the rendered HTML is OK; the call is bounded by document
        // size and avoids walking every node's style attribute.
        let html = outerHTML()
        let lowerHTML = html.lowercased()
        var searchIndex = lowerHTML.startIndex
        let cidScheme = "cid:"
        while let range = lowerHTML.range(of: cidScheme, range: searchIndex..<lowerHTML.endIndex) {
            let valueStart = range.upperBound
            var end = valueStart
            while end < lowerHTML.endIndex {
                let char = lowerHTML[end]
                if char == "\"" || char == "'" || char == " " || char == "," ||
                    char == ")" || char == ">" || char == "<" {
                    break
                }
                end = lowerHTML.index(after: end)
            }
            if valueStart < end {
                let id = String(lowerHTML[valueStart..<end])
                if let normalized = Self.normalizedContentID(id) {
                    result.insert(normalized)
                }
            }
            searchIndex = end
        }
        return result
    }

    // MARK: - Render quality metrics

    func renderQualityMetrics(
        footerLineHints: [String],
        primaryContentHints: [String]
    ) -> EmailDocumentRenderQualityMetrics {
        let bodyRoot = document.body() ?? document

        return EmailDocumentRenderQualityMetrics(
            imageCount: selectedElements("img", root: bodyRoot).count,
            tableCount: selectedElements("table", root: bodyRoot).count,
            linkCount: selectedElements("a[href]", root: bodyRoot).count,
            semanticElementCount: selectedElements(Self.semanticElementSelector, root: bodyRoot).count,
            elementCount: selectedElements("*", root: bodyRoot).count,
            largeSpacerSignalCount: largeSpacerSignalCount(in: bodyRoot),
            hiddenPrimaryContentCount: hiddenPrimaryContentCount(
                in: bodyRoot,
                primaryContentHints: primaryContentHints
            ),
            footerLineRatio: Self.footerLineRatio(
                in: plainText(preserveParagraphs: true),
                hints: footerLineHints
            )
        )
    }

    func hiddenPrimaryContentCount(primaryContentHints: [String]) -> Int {
        hiddenPrimaryContentCount(
            in: document.body() ?? document,
            primaryContentHints: primaryContentHints
        )
    }

    func renderablePlainText(preserveParagraphs: Bool = true) -> String {
        let text = EmailDOMTextExtractor.paragraphAwareText(
            from: document,
            skipping: isNonRenderableContentElement
        )
        guard !preserveParagraphs else {
            return text
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func renderableQualityMetrics(
        footerLineHints: [String],
        primaryContentHints: [String]
    ) -> EmailDocumentRenderQualityMetrics {
        let bodyRoot = document.body() ?? document

        return EmailDocumentRenderQualityMetrics(
            imageCount: renderableElements("img", root: bodyRoot).count,
            tableCount: renderableElements("table", root: bodyRoot).count,
            linkCount: renderableElements("a[href]", root: bodyRoot).count,
            semanticElementCount: renderableElements(Self.semanticElementSelector, root: bodyRoot).count,
            elementCount: renderableElements("*", root: bodyRoot).count,
            largeSpacerSignalCount: renderableElements("td,tr,div,table,p", root: bodyRoot)
                .filter(Self.isLargeSpacerElement)
                .count,
            hiddenPrimaryContentCount: hiddenPrimaryContentCount(
                in: bodyRoot,
                primaryContentHints: primaryContentHints
            ),
            footerLineRatio: Self.footerLineRatio(
                in: renderablePlainText(preserveParagraphs: true),
                hints: footerLineHints
            )
        )
    }

    func htmlMetrics() -> EmailDocumentHTMLMetrics {
        let bodyRoot = document.body() ?? document
        return EmailDocumentHTMLMetrics(
            imageCount: selectedElements("img", root: bodyRoot).count,
            tableCount: selectedElements("table", root: bodyRoot).count,
            linkCount: selectedElements("a[href]", root: bodyRoot).count
        )
    }

    func previewPlainText() -> String? {
        EmailPreviewDOMQuery(document: document).plainText()
    }

    func previewHTMLSummary() -> EmailPreviewHTMLSummary {
        EmailPreviewDOMQuery(document: document).htmlSummary()
    }

    /// Normalizes a `cid:` URL or raw Content-ID to a lowercase identifier
    /// suitable for matching against `Attachment.contentId`. Mirrors the
    /// semantics of `MessageBubbleHTMLAnalysisBuilder.normalizedContentID`.
    static func normalizedContentID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("cid:") {
            normalized = String(normalized.dropFirst(4))
        }
        normalized = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        normalized = normalized.removingPercentEncoding ?? normalized
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        guard !normalized.isEmpty else { return nil }
        return normalized.lowercased()
    }

    private static func cidIdentifier(from attributeValue: String) -> String? {
        let trimmed = attributeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cid:") else { return nil }
        let identifier = String(trimmed.dropFirst(4))
        return normalizedContentID(identifier)
    }

    private static func cidIdentifiers(inSrcset srcset: String) -> Set<String> {
        srcset
            .split(separator: ",")
            .reduce(into: Set<String>()) { result, candidate in
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = trimmed.split(whereSeparator: { $0.isWhitespace }).first,
                      let cid = cidIdentifier(from: String(url)) else {
                    return
                }
                result.insert(cid)
            }
    }

    private func selectedElements(_ selector: String, root: Element? = nil) -> [Element] {
        let root = root ?? document
        return ((try? root.select(selector)) ?? Elements()).array()
    }

    private func renderableElements(_ selector: String, root: Element) -> [Element] {
        selectedElements(selector, root: root).filter { !hasNonRenderableAncestorOrSelf($0) }
    }

    private func largeSpacerSignalCount(in root: Element) -> Int {
        selectedElements("td,tr,div,table,p", root: root).filter(Self.isLargeSpacerElement).count
    }

    private func hiddenPrimaryContentCount(
        in root: Element,
        primaryContentHints: [String]
    ) -> Int {
        let inlineHiddenPrimaryCount = selectedElements("a,table,div,td", root: root).filter { element in
            guard Self.elementIdentifierContainsHint(element, hints: primaryContentHints) else {
                return false
            }
            return Self.isHiddenByInlineStyle(element)
        }.count

        let hiddenLinkCount = selectedElements("a", root: root).filter(Self.isHiddenByInlineStyle).count

        return inlineHiddenPrimaryCount + hiddenLinkCount + stylesheetHiddenPrimaryContentCount(
            root: root,
            primaryContentHints: primaryContentHints
        )
    }

    private func stylesheetHiddenPrimaryContentCount(
        root: Element,
        primaryContentHints: [String]
    ) -> Int {
        selectedElements("style").reduce(into: 0) { count, styleElement in
            let css = Self.removingCSSComments(from: (try? styleElement.html()) ?? "")
            var searchIndex = css.startIndex

            while let openBrace = css[searchIndex...].firstIndex(of: "{") {
                let selectorStart = Self.selectorStart(in: css, before: openBrace)
                let closeBrace = css[openBrace...].firstIndex(of: "}") ?? css.endIndex
                let declarationStart = css.index(after: openBrace)
                let selector = String(css[selectorStart..<openBrace])
                let declaration = String(css[declarationStart..<closeBrace])

                if Self.selectorContainsHint(selector, hints: primaryContentHints),
                   Self.styleDeclarationHidesContent(declaration) {
                    let matchingElements = matchingElementCount(for: selector, root: root)
                    count += max(matchingElements, 1)
                }

                searchIndex = css.index(after: openBrace)
            }
        }
    }

    private func matchingElementCount(for selectorText: String, root: Element) -> Int {
        selectorText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: 0) { count, selector in
                count += ((try? root.select(selector)) ?? Elements()).array().count
            }
    }

    private static func isLargeSpacerElement(_ element: Element) -> Bool {
        if numericAttribute("height", in: element).map({ $0 >= 40 }) == true {
            return true
        }

        let style = ((try? element.attr("style")) ?? "").lowercased()
        if cssPixelValue(in: style, for: ["height", "min-height"]).map({ $0 >= 40 }) == true {
            return true
        }

        let tagName = element.tagName().lowercased()
        guard tagName == "td" || tagName == "div" || tagName == "p" else {
            return false
        }
        return containsOnlySpacerContent(element)
    }

    private static func containsOnlySpacerContent(_ element: Element) -> Bool {
        var spacerUnits = 0
        var sawContent = false

        for child in element.getChildNodes() {
            if let textNode = child as? TextNode {
                for character in textNode.text() {
                    guard character.isWhitespace || character == "\u{00A0}" else {
                        return false
                    }
                    spacerUnits += 1
                    sawContent = true
                }
                continue
            }

            if let childElement = child as? Element,
               childElement.tagName().lowercased() == "br" {
                spacerUnits += 2
                sawContent = true
                continue
            }

            return false
        }

        return sawContent && spacerUnits >= 8
    }

    private static func numericAttribute(_ name: String, in element: Element) -> Double? {
        let rawValue = ((try? element.attr(name)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return leadingNumber(in: rawValue)
    }

    private static func cssPixelValue(in style: String, for propertyNames: Set<String>) -> Double? {
        for declaration in style.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = declaration.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let property = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard propertyNames.contains(property) else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard value.contains("px") else { continue }

            if let number = leadingNumber(in: value) {
                return number
            }
        }

        return nil
    }

    private static func leadingNumber(in text: String) -> Double? {
        var number = ""
        var hasDecimalPoint = false

        for character in text {
            if character.isNumber {
                number.append(character)
                continue
            }

            if character == ".", !hasDecimalPoint {
                number.append(character)
                hasDecimalPoint = true
                continue
            }

            break
        }

        guard !number.isEmpty, number != "." else {
            return nil
        }
        return Double(number)
    }

    private static func elementIdentifierContainsHint(_ element: Element, hints: [String]) -> Bool {
        let identifiers = [
            (try? element.attr("class")) ?? "",
            (try? element.attr("id")) ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        return hints.contains { identifiers.contains($0) }
    }

    private static func selectorContainsHint(_ selector: String, hints: [String]) -> Bool {
        let lowercased = selector.lowercased()
        guard lowercased.contains(".") || lowercased.contains("#") else {
            return false
        }
        return hints.contains { lowercased.contains($0) }
    }

    private static func isHiddenByInlineStyle(_ element: Element) -> Bool {
        styleDeclarationHidesContent((try? element.attr("style")) ?? "")
    }

    private static func styleDeclarationHidesContent(_ style: String) -> Bool {
        let compact = style.lowercased().filter { !$0.isWhitespace }
        return compact.contains("display:none") ||
            compact.contains("visibility:hidden")
    }

    private func hasNonRenderableAncestorOrSelf(_ element: Element) -> Bool {
        var current: Element? = element
        while let element = current {
            if isNonRenderableContentElement(element) {
                return true
            }
            current = element.parent()
        }
        return false
    }

    private func isNonRenderableContentElement(_ element: Element) -> Bool {
        if (try? element.hasAttr("hidden")) == true {
            return true
        }

        if Self.styleDeclarationRemovesRenderableContent((try? element.attr("style")) ?? "") {
            return true
        }

        let className = ((try? element.attr("class")) ?? "").lowercased()
        return className.range(of: #"\bm-hide\b|\bpreheader\b|\bpreview-text\b"#, options: .regularExpression) != nil
    }

    private static func styleDeclarationRemovesRenderableContent(_ style: String) -> Bool {
        let compact = style.lowercased().filter { !$0.isWhitespace }
        return compact.contains("display:none") ||
            compact.contains("visibility:hidden") ||
            compact.contains("mso-hide:all") ||
            compact.range(of: #"opacity:0(?:\.0+)?(?:!important)?(?:;|$)"#, options: .regularExpression) != nil
    }

    private static func removingCSSComments(from css: String) -> String {
        var result = css
        while let start = result.range(of: "/*") {
            guard let end = result.range(of: "*/", range: start.upperBound..<result.endIndex) else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
                break
            }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    private static func selectorStart(in css: String, before openBrace: String.Index) -> String.Index {
        var index = openBrace
        while index > css.startIndex {
            let previous = css.index(before: index)
            if css[previous] == "{" || css[previous] == "}" {
                return css.index(after: previous)
            }
            index = previous
        }
        return css.startIndex
    }

    private static func footerLineRatio(in text: String, hints: [String]) -> Double {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return 0 }

        let footerLines = lines.filter { line in
            hints.contains { line.contains($0) }
        }.count

        return Double(footerLines) / Double(lines.count)
    }

    private static let semanticElementSelector = [
        "p",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "li",
        "ul",
        "ol",
        "article",
        "section",
        "main"
    ].joined(separator: ",")

}

/// Parses standalone table-section fragments with their required parent
/// context so SwiftSoup does not foster their cells into plain body text.
enum EmailDOMFragmentParser {
    static func parse(_ html: String, inputIsFragment: Bool) throws -> Document {
        if inputIsFragment, let contextTagName = tableFragmentContextTagName(for: html) {
            return try parseFragment(html, contextTagName: contextTagName)
        }

        if inputIsFragment {
            return try SwiftSoup.parseBodyFragment(html)
        }
        return try SwiftSoup.parse(html)
    }

    private static func parseFragment(_ html: String, contextTagName: String) throws -> Document {
        let document = Document.createShell("")
        guard let body = document.body() else {
            return try SwiftSoup.parseBodyFragment(html)
        }

        let context = try Element(Tag.valueOf(contextTagName), "")
        let nodes = try Parser.parseFragment(html, context, [UInt8]())
        for node in nodes {
            try body.appendChild(node)
        }
        return document
    }

    private static func tableFragmentContextTagName(for html: String) -> String? {
        guard let tagName = leadingOpeningTagName(in: html) else {
            return nil
        }

        switch tagName {
        case "caption", "colgroup", "tbody", "tfoot", "thead":
            return "table"
        case "col":
            return "colgroup"
        case "tr":
            return "tbody"
        case "td", "th":
            return "tr"
        default:
            return nil
        }
    }

    private static func leadingOpeningTagName(in html: String) -> String? {
        var index = html.startIndex

        while index < html.endIndex {
            while index < html.endIndex, html[index].isWhitespace {
                index = html.index(after: index)
            }
            guard index < html.endIndex else { return nil }
            guard html[index] == "<" else { return nil }

            let afterOpen = html.index(after: index)
            guard afterOpen < html.endIndex else { return nil }

            if html[afterOpen...].hasPrefix("!--") {
                guard let commentEnd = html[afterOpen...].range(of: "-->")?.upperBound else {
                    return nil
                }
                index = commentEnd
                continue
            }

            guard html[afterOpen].isLetter else {
                return nil
            }

            var nameEnd = afterOpen
            while nameEnd < html.endIndex, isTagNameCharacter(html[nameEnd]) {
                nameEnd = html.index(after: nameEnd)
            }

            return String(html[afterOpen..<nameEnd]).lowercased()
        }

        return nil
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_"
    }
}
