import Foundation
import SwiftSoup

/// DOM-based first pass for `HTMLSanitizerService`.
///
/// This intentionally covers only dangerous element removal and event-handler
/// attribute stripping. URL, tracking-pixel, and CSS sanitization remain in the
/// existing specialized sanitizers so the rollout can compare one layer at a
/// time.
enum EmailDOMHTMLSanitizer {
    static let dangerousTags = [
        "script", "noscript", "object", "embed", "applet",
        "frame", "frameset", "iframe", "base", "basefont",
        "form", "input", "button", "select", "textarea",
        "option", "optgroup", "fieldset", "legend", "label",
        "meta", "link",
        // Inline SVG is removed as a whole in email HTML. SVG has active
        // subcontent (`foreignObject`, animations, `set`) and URL-bearing
        // reference elements (`use`, `image`, `feImage`) whose safe subset is
        // not needed by the app today, so we do not attempt a partial allowlist.
        "svg", "foreignobject", "animate", "animatemotion", "animatetransform",
        "set", "use", "image", "feimage"
    ]

    private static let dangerousTagSet = Set(dangerousTags)
    private static let dangerousTagsRequiringMarkupEvidence: Set<String> = [
        "foreignobject", "animate", "animatemotion", "animatetransform",
        "set", "use", "image", "feimage"
    ]
    private static let knownHTMLTagSet = dangerousTagSet
        .subtracting(dangerousTagsRequiringMarkupEvidence)
        .union([
            "a", "abbr", "address", "area", "article", "aside", "audio",
            "b", "bdi", "bdo", "blockquote", "body", "br",
            "caption", "center", "cite", "code", "col", "colgroup",
            "data", "datalist", "dd", "del", "details", "dfn", "dialog", "dir", "div", "dl", "dt",
            "em", "figcaption", "figure", "font", "footer",
            "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html",
            "i", "img", "ins", "kbd", "li", "main", "map", "mark", "menu", "meter",
            "nav", "ol", "p", "picture", "pre", "progress",
            "q", "rp", "rt", "ruby", "s", "samp", "section", "small", "source",
            "span", "strike", "strong", "style", "sub", "summary", "sup",
            "table", "tbody", "td", "template", "tfoot", "th", "thead", "time", "title", "tr", "track",
            "u", "ul", "var", "video", "wbr"
        ])
    private static let dangerousSelector = dangerousTags.joined(separator: ",")

    static func removeDangerousElementsAndEventHandlers(from html: String) throws -> String {
        guard containsLikelyHTMLTag(html) else {
            return html
        }

        let inputIsFragment = !hasDocumentWrapper(html)
        let parseableHTML = normalizeDangerousTagBoundaries(in: html)
        let document = try EmailDOMFragmentParser.parse(
            parseableHTML,
            inputIsFragment: inputIsFragment
        )

        document.outputSettings().prettyPrint(pretty: false)

        try removeDangerousElements(in: document)
        try removeEventHandlerAttributes(in: document)

        if inputIsFragment, let body = document.body() {
            return try body.html()
        }
        return preserveOriginalDoctypeCasing(in: try document.outerHtml(), originalHTML: html)
    }

    private static func removeDangerousElements(in document: Document) throws {
        let elements = try document.select(dangerousSelector)
        try elements.remove()
    }

    private static func removeEventHandlerAttributes(in document: Document) throws {
        let elements = try document.select("*")
        for element in elements.array() {
            let eventAttributeNames = element.getAttributes()?.asList()
                .map { $0.getKey() }
                .filter { $0.lowercased().hasPrefix("on") } ?? []

            for attributeName in eventAttributeNames {
                try element.removeAttr(attributeName)
            }
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

    private static func containsLikelyHTMLTag(_ html: String) -> Bool {
        var index = html.startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            let nextIndex = html.index(after: tagStart)
            guard nextIndex < html.endIndex else { return false }

            let firstCharacter = html[nextIndex]
            if firstCharacter.isLetter,
               let tagEnd = tagEndIndex(in: html, from: nextIndex) {
                let tagNameStart = nextIndex
                var tagNameEnd = tagNameStart
                while tagNameEnd < html.endIndex, isTagNameCharacter(html[tagNameEnd]) {
                    tagNameEnd = html.index(after: tagNameEnd)
                }

                let tagName = String(html[tagNameStart..<tagNameEnd]).lowercased()
                if knownHTMLTagSet.contains(tagName) ||
                    tagHasAttributes(in: html, nameEnd: tagNameEnd, tagEnd: tagEnd) ||
                    hasExplicitCloseTag(named: tagName, in: html, after: html.index(after: tagEnd)) {
                    return true
                }
            } else if firstCharacter == "!",
                      html[nextIndex...].lowercased().hasPrefix("!doctype"),
                      tagEndIndex(in: html, from: nextIndex) != nil {
                return true
            }
            if firstCharacter == "/" {
                let nameStart = html.index(after: nextIndex)
                var nameEnd = nameStart
                while nameEnd < html.endIndex, isTagNameCharacter(html[nameEnd]) {
                    nameEnd = html.index(after: nameEnd)
                }

                let tagName = String(html[nameStart..<nameEnd]).lowercased()
                if nameStart < html.endIndex,
                   html[nameStart].isLetter,
                   knownHTMLTagSet.contains(tagName),
                   tagEndIndex(in: html, from: nameEnd) != nil {
                    return true
                }
            }

            index = nextIndex
        }

        return false
    }

    /// SwiftSoup follows HTML parser rules, so invalid self-closing tags like
    /// `<iframe/>` can otherwise consume following sibling content. Close only
    /// dangerous tags before parsing so their removal does not eat safe content.
    private static func normalizeDangerousTagBoundaries(in html: String) -> String {
        var output = ""
        var index = html.startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            output.append(contentsOf: html[index..<tagStart])

            let afterOpen = html.index(after: tagStart)
            guard afterOpen < html.endIndex else {
                output.append(contentsOf: html[tagStart...])
                return output
            }

            if html[afterOpen] == "!" || html[afterOpen] == "?" || html[afterOpen] == "/" {
                guard let tagEnd = tagEndIndex(in: html, from: afterOpen) else {
                    output.append(contentsOf: html[tagStart...])
                    return output
                }
                output.append(contentsOf: html[tagStart...tagEnd])
                index = html.index(after: tagEnd)
                continue
            }

            let tagNameStart = afterOpen
            var tagNameEnd = tagNameStart
            while tagNameEnd < html.endIndex, isTagNameCharacter(html[tagNameEnd]) {
                tagNameEnd = html.index(after: tagNameEnd)
            }

            let tagName = String(html[tagNameStart..<tagNameEnd]).lowercased()
            guard dangerousTagSet.contains(tagName),
                  let tagEnd = tagEndIndex(in: html, from: tagNameEnd) else {
                guard let tagEnd = tagEndIndex(in: html, from: afterOpen) else {
                    output.append(contentsOf: html[tagStart...])
                    return output
                }
                output.append(contentsOf: html[tagStart...tagEnd])
                index = html.index(after: tagEnd)
                continue
            }

            let afterTagEnd = html.index(after: tagEnd)
            let hasExplicitClose = hasExplicitCloseTag(
                named: tagName,
                in: html,
                after: afterTagEnd,
                stoppingAtSameNameOpen: true
            )
            let selfClosingSlash = selfClosingSlashIndex(in: html, before: tagEnd)

            if let selfClosingSlash {
                output.append(contentsOf: html[tagStart..<selfClosingSlash])
                output.append(contentsOf: html[html.index(after: selfClosingSlash)...tagEnd])
                output.append("</\(tagName)>")
            } else if !hasExplicitClose {
                output.append(contentsOf: html[tagStart...tagEnd])
                output.append("</\(tagName)>")
            } else {
                output.append(contentsOf: html[tagStart...tagEnd])
            }

            index = afterTagEnd
        }

        output.append(contentsOf: html[index...])
        return output
    }

    private static func tagEndIndex(in html: String, from startIndex: String.Index) -> String.Index? {
        var index = startIndex
        var quote: Character?

        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }

            index = html.index(after: index)
        }

        return nil
    }

    private static func selfClosingSlashIndex(in html: String, before tagEnd: String.Index) -> String.Index? {
        var index = html.index(before: tagEnd)
        while index > html.startIndex, html[index].isWhitespace {
            index = html.index(before: index)
        }
        return html[index] == "/" ? index : nil
    }

    private static func tagHasAttributes(in html: String, nameEnd: String.Index, tagEnd: String.Index) -> Bool {
        var index = nameEnd
        var hasAttributeSeparator = false

        while index < tagEnd {
            if html[index].isWhitespace {
                hasAttributeSeparator = true
                index = html.index(after: index)
                continue
            }

            guard hasAttributeSeparator, html[index] != "/" else {
                return false
            }

            let attributeNameStart = index
            while index < tagEnd, isAttributeNameCharacter(html[index]) {
                index = html.index(after: index)
            }

            guard attributeNameStart < index else {
                return false
            }

            while index < tagEnd, html[index].isWhitespace {
                index = html.index(after: index)
            }

            if index < tagEnd, html[index] == "=" {
                return true
            }

            hasAttributeSeparator = false
        }

        return false
    }

    private static func preserveOriginalDoctypeCasing(in sanitizedHTML: String, originalHTML: String) -> String {
        guard let originalRange = originalHTML.range(of: "<!doctype", options: .caseInsensitive),
              let sanitizedRange = sanitizedHTML.range(of: "<!doctype", options: .caseInsensitive) else {
            return sanitizedHTML
        }

        var restored = sanitizedHTML
        restored.replaceSubrange(sanitizedRange, with: originalHTML[originalRange])
        return restored
    }

    private static func hasExplicitCloseTag(
        named tagName: String,
        in html: String,
        after startIndex: String.Index,
        stoppingAtSameNameOpen: Bool = false
    ) -> Bool {
        var index = startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            let afterOpen = html.index(after: tagStart)
            guard afterOpen < html.endIndex else { return false }

            if html[afterOpen...].hasPrefix("!--") {
                guard let commentEnd = html[afterOpen...].range(of: "-->")?.upperBound else {
                    return false
                }
                index = commentEnd
                continue
            }

            if stoppingAtSameNameOpen,
               isOpeningTag(named: tagName, in: html, startingAt: afterOpen) {
                return false
            }

            guard html[afterOpen] == "/" else {
                index = afterOpen
                continue
            }

            let nameStart = html.index(after: afterOpen)
            var nameEnd = nameStart
            while nameEnd < html.endIndex, isTagNameCharacter(html[nameEnd]) {
                nameEnd = html.index(after: nameEnd)
            }

            guard String(html[nameStart..<nameEnd]).caseInsensitiveCompare(tagName) == .orderedSame,
                  let tagEnd = tagEndIndex(in: html, from: nameEnd) else {
                index = nameEnd
                continue
            }

            var closeRemainder = nameEnd
            while closeRemainder < tagEnd, html[closeRemainder].isWhitespace {
                closeRemainder = html.index(after: closeRemainder)
            }

            if closeRemainder == tagEnd {
                return true
            }

            index = html.index(after: tagEnd)
        }

        return false
    }

    private static func isOpeningTag(
        named tagName: String,
        in html: String,
        startingAt nameStart: String.Index
    ) -> Bool {
        guard nameStart < html.endIndex, html[nameStart].isLetter else {
            return false
        }

        var nameEnd = nameStart
        while nameEnd < html.endIndex, isTagNameCharacter(html[nameEnd]) {
            nameEnd = html.index(after: nameEnd)
        }

        guard String(html[nameStart..<nameEnd]).caseInsensitiveCompare(tagName) == .orderedSame,
              tagEndIndex(in: html, from: nameEnd) != nil else {
            return false
        }

        return true
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_"
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        !character.isWhitespace &&
            character != "/" &&
            character != ">" &&
            character != "=" &&
            character != "\"" &&
            character != "'" &&
            character != "<"
    }
}
