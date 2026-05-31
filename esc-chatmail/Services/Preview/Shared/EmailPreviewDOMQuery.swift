import Foundation
import SwiftSoup

struct EmailPreviewDOMQuery {
    private let document: Document

    init(document: Document) {
        self.document = document
    }

    init?(html: String) {
        do {
            let document = try SwiftSoup.parse(html)
            document.outputSettings().prettyPrint(pretty: false)
            self.document = document
        } catch {
            return nil
        }
    }

    func plainText() -> String? {
        PreviewTextUtilities.normalizedPreviewText(
            EmailDOMTextExtractor.paragraphAwareText(from: document)
        )
    }

    func htmlSummary(maxActionLinks: Int = 12, maxScannedLinks: Int = 48) -> EmailPreviewHTMLSummary {
        EmailPreviewHTMLSummary(
            h1Text: firstText(matching: "h1"),
            h2Text: firstText(matching: "h2"),
            titleText: firstText(matching: "title"),
            preheaderText: firstPreheaderText(),
            actionLinkTexts: actionLinkTexts(maxLinks: maxActionLinks, maxScannedLinks: maxScannedLinks)
        )
    }

    func images(maxImages: Int = 12) -> [EmailPreviewImage] {
        guard maxImages > 0 else {
            return []
        }

        let imageElements = Array(selectedElements("img").prefix(maxImages))
        return imageElements.enumerated().compactMap { index, element in
            guard let sourceURL = attributeValue(named: "src", in: element) else {
                return nil
            }

            let descriptor = [
                attributeValue(named: "alt", in: element),
                attributeValue(named: "class", in: element)
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            let nextImage = imageElements.indices.contains(index + 1) ? imageElements[index + 1] : nil
            return EmailPreviewImage(
                sourceURL: sourceURL,
                width: numericAttribute(named: "width", in: element),
                height: numericAttribute(named: "height", in: element),
                descriptor: descriptor,
                followingText: followingTextAfterImage(element, stoppingAt: nextImage),
                index: index
            )
        }
    }

    private func firstText(matching selector: String) -> String? {
        selectedElements(selector).lazy.compactMap(normalizedElementText).first
    }

    private func firstPreheaderText() -> String? {
        selectedElements("div,span").lazy.compactMap { element -> String? in
            let identifiers = [
                attributeValue(named: "class", in: element),
                attributeValue(named: "id", in: element)
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            guard identifiers.contains("preheader") else {
                return nil
            }

            return normalizedElementText(element)
        }.first
    }

    private func actionLinkTexts(maxLinks: Int, maxScannedLinks: Int) -> [String] {
        guard maxLinks > 0, maxScannedLinks > 0 else {
            return []
        }

        var linkTexts: [String] = []
        for element in selectedElements("a").prefix(maxScannedLinks) {
            guard let text = normalizedElementText(element) else {
                continue
            }

            linkTexts.append(text)
            if linkTexts.count >= maxLinks {
                break
            }
        }

        return linkTexts
    }

    private func selectedElements(_ selector: String) -> [Element] {
        ((try? document.select(selector)) ?? Elements()).array()
    }

    private func normalizedElementText(_ element: Element) -> String? {
        PreviewTextUtilities.normalizedPreviewText((try? element.text()) ?? "")
    }

    private func attributeValue(named attribute: String, in element: Element) -> String? {
        let value = PreviewTextUtilities.normalizedText((try? element.attr(attribute)) ?? "")
        return value.isEmpty ? nil : value
    }

    private func numericAttribute(named attribute: String, in element: Element) -> Int? {
        guard let value = attributeValue(named: attribute, in: element) else {
            return nil
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)"#,
            options: []
        ),
              let match = regex.firstMatch(in: value, options: [], range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else {
            return nil
        }

        return roundedPositiveInteger(from: String(value[range]))
    }

    private func roundedPositiveInteger(from numericValue: String) -> Int? {
        var value = numericValue
        if value.hasPrefix("-") {
            return nil
        }

        if value.hasPrefix("+") {
            value.removeFirst()
        }

        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = parts.first.map(String.init) ?? ""
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        let integerDigits = integerPart.drop { $0 == "0" }
        let normalizedInteger = integerDigits.isEmpty ? "0" : String(integerDigits)
        let maxInteger = String(Int.max)

        guard normalizedInteger.count < maxInteger.count
                || (normalizedInteger.count == maxInteger.count && normalizedInteger <= maxInteger),
              var rounded = Int(normalizedInteger) else {
            return nil
        }

        if let firstFractionDigit = fractionPart.first,
           (firstFractionDigit.wholeNumberValue ?? 0) >= 5 {
            guard rounded < Int.max else {
                return nil
            }
            rounded += 1
        }

        guard rounded > 0 else {
            return nil
        }
        return rounded
    }

    private func followingTextAfterImage(_ image: Element, stoppingAt nextImage: Element?) -> String {
        let collector = FollowingImageTextCollector(targetImage: image, nextImage: nextImage)
        collector.walk(node: document.body() ?? document)
        return PreviewTextUtilities.normalizedText(collector.text)
    }
}

private final class FollowingImageTextCollector {
    private enum State {
        case searching
        case collecting
        case finished
    }

    private let targetImage: Element
    private let nextImage: Element?
    private var state: State = .searching
    private var remainingCharacterCount = 2_500

    private(set) var text = ""

    init(targetImage: Element, nextImage: Element?) {
        self.targetImage = targetImage
        self.nextImage = nextImage
    }

    func walk(node: Node) {
        guard state != .finished, remainingCharacterCount > 0 else {
            return
        }

        if let textNode = node as? TextNode {
            if state == .collecting {
                append(textNode.text())
            }
            return
        }

        guard let element = node as? Element else {
            return
        }

        if element === targetImage {
            state = .collecting
            return
        }

        if state == .collecting, let nextImage, element === nextImage {
            state = .finished
            return
        }

        let tagName = element.tagName().lowercased()
        if Self.invisibleTags.contains(tagName) {
            return
        }

        if state == .collecting, tagName == "br" {
            append("\n")
            return
        }

        if state == .collecting, Self.blockTags.contains(tagName) {
            append("\n")
        }

        for child in element.getChildNodes() {
            walk(node: child)
            if state == .finished || remainingCharacterCount <= 0 {
                return
            }
        }

        if state == .collecting, Self.cellTags.contains(tagName) {
            append(" ")
        }

        if state == .collecting, Self.blockTags.contains(tagName) {
            append("\n")
        }
    }

    private func append(_ value: String) {
        guard !value.isEmpty, remainingCharacterCount > 0 else {
            return
        }

        if value.count <= remainingCharacterCount {
            text += value
            remainingCharacterCount -= value.count
            return
        }

        text.append(contentsOf: value.prefix(remainingCharacterCount))
        remainingCharacterCount = 0
    }

    private static let invisibleTags: Set<String> = [
        "script", "style", "head", "title", "meta", "link", "noscript", "template"
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "nav",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre",
        "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr",
        "address", "figure", "figcaption", "hr"
    ]

    private static let cellTags: Set<String> = ["td", "th"]
}
