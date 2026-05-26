import Foundation
import SwiftSoup

/// A parsed HTML email document with DOM-based operations.
///
/// `EmailDocument` is the canonical DOM representation used by the new HTML
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
        // Disable pretty-printing so emitted HTML stays close to the input. This
        // matters because the legacy regex pipeline preserves whitespace
        // exactly; reflowed output would diverge for whitespace-sensitive
        // comparisons in tests.
        document.outputSettings().prettyPrint(pretty: false)
        return EmailDocument(document: document)
    }

    /// Convenience: parses HTML, returning nil on any failure (including throws).
    /// Use this at boundaries where graceful degradation is wanted; the caller
    /// can fall back to the legacy regex path on `nil`.
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
    func plainText(preserveParagraphs: Bool = true) -> String {
        guard preserveParagraphs else {
            return (try? document.text()) ?? ""
        }
        return EmailDOMTextExtractor.paragraphAwareText(from: document)
    }

    // MARK: - Inline content IDs

    /// Returns the set of `cid:` references found in `src` / `background` /
    /// `href` attributes, normalized to lowercase identifiers without the
    /// `cid:` prefix.
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
                if char == "\"" || char == "'" || char == " " || char == ")" || char == ">" || char == "<" {
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

    /// Normalizes a `cid:` URL or raw Content-ID to a lowercase identifier
    /// suitable for matching against `Attachment.contentId`. Mirrors the
    /// semantics of `MessageBubbleHTMLAnalysisBuilder.normalizedContentID`.
    static func normalizedContentID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        normalized = normalized.removingPercentEncoding ?? normalized
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized.lowercased()
    }

    private static func cidIdentifier(from attributeValue: String) -> String? {
        let trimmed = attributeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cid:") else { return nil }
        let identifier = String(trimmed.dropFirst(4))
        return normalizedContentID(identifier)
    }

}
