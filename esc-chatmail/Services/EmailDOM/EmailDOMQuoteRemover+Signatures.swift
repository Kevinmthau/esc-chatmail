import Foundation
import SwiftSoup

// Signature removal — two coupled passes that share sign-off / name-line
// detection, so they live in one file:
//   1. Signature wrappers — remove gmail_signature / ms-outlook-signature /
//      .signature containers, preserving a bare sign-off (+ name) line.
//   2. Signature text markers — truncate at "Sent from my iPhone" / "Sent from
//      Outlook", confidentiality / wire-fraud boilerplate, and trailing
//      contact-card signatures detected heuristically.
// Builds on the tree-surgery layer (collectTextNodes, visibleLineElements,
// truncateAtTextNode). isContactSignatureLine / containsEmailAddress are also
// used by the structural-boundaries pass, hence internal.
extension EmailDOMQuoteRemover {

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

    static func removeSignatureWrappers(in document: Document) throws {
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

        guard lines.count > 1, SignatureSignOffPolicy.shouldPreserveNameLine(lines[1]) else { return "" }
        let preserved = [lines[0], lines[1]]

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
                return SignatureSignOffPolicy.shouldPreserveNameLine(remainder)
            }
        }

        return false
    }

    private static func looksLikeNameLine(_ line: String) -> Bool {
        SignatureSignOffPolicy.looksLikeNameLine(line)
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

    private static let signOffPhrases = SignaturePatterns.signOffPhrases

    private static let signOffPhrasesForPrefixMatching: [String] = signOffPhrases.sorted {
        if $0.count == $1.count {
            return $0 < $1
        }
        return $0.count > $1.count
    }

    static func truncateAtSignatureMarkers(in document: Document) throws {
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

    private static let signatureEmailPattern = EmailPatterns.address

    private static let signatureURLPattern = URLPatterns.webURL

    private static let signaturePhonePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_])\+?\(?\d(?:[\d\s().-]*\d)?"#,
            options: []
        )
    }()

    private static let signaturePhoneKnownLabelPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:m|c|o|f|d|t|p|w|h|tel|tél|telephone(?:\s+number)?|"# +
                #"téléphone(?:\s+number)?|"# +
                #"telefono|teléfono|telefon|"# +
                #"phone(?:\s+number)?|cell(?:ular)?(?:\s+(?:phone|number))?|"# +
                #"mobile(?:\s+(?:phone|number))?|office(?:\s+phone)?|"# +
                #"m[oó]vil|portable|"# +
                #"work(?:\s+phone)?|home(?:\s+phone)?|direct(?:\s+(?:phone|line))?|"# +
                #"desk(?:\s+(?:phone|line))?|main(?:\s+(?:phone|line))?|fax)\s*(?:[:.]|\|)?$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let signaturePhoneExtensionPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:x|ext\.?|extension|#)\s*:?\s*\d+\s*[.,;]?$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let signaturePhoneSuffixLabelPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:\([\p{L}\p{M}][\p{L}\p{M}-]{0,20}\)|"# +
                #"mobile|cell|office|work|home|direct|desk|main|fax)\s*[.,;]?$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let signatureNonPhoneDatePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:(?:19|20)\d{2}(?:-|\.)(?:\d{1,2}(?:-|\.)\d{1,2}|\d{4})|"# +
                #"\d{1,2}(?:-|\.)\d{1,2}(?:-|\.)(?:19|20)\d{2})$"#,
            options: []
        )
    }()

    private static let signatureAddressPattern = SignaturePatterns.addressKeyword

    private static let signatureTimeRangePattern = try? NSRegularExpression(
        pattern: #"^(?:[01]?\d|2[0-3])[.:]?[0-5]\d-(?:(?:[01]?\d|2[0-3])[.:]?[0-5]\d|24[.:]?00)$"#
    )

    private static let signatureBareHoursLabelPattern = try? NSRegularExpression(
        pattern: #"^after[ -]hours\s*:$"#, options: [.caseInsensitive]
    )

    private static let signatureCityStateZipPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^[A-Z][A-Z .'-]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let signatureStandaloneContactLabelPattern = SignaturePatterns.standaloneContactLabel

    private static let contactListIntroKeywords: [String] = [
        "contact", "email", "reviewer", "recipient"
    ]

    // The inclusive DOM window includes lastNonEmpty - 80; blank separators consume slots.
    private static let trailingSignatureLookback = 80

    private struct SignatureLine {
        let element: Element
        let text: String
        let startTextNode: TextNode?
        let startUTF16Offset: Int
        let links: [VisibleLineLink]
        let nonLinkText: String
    }

    /// Expand only signature scanning: quote/header passes retain their existing line units.
    private static func signatureLines(in body: Element) -> [SignatureLine] {
        visibleLineElements(in: body, includingEmpty: true).flatMap { line in
            let element = line.element
            let cells = element.tagNameNormal() == "tr" ? element.children().array().filter {
                ["td", "th"].contains($0.tagNameNormal())
            } : []
            if !cells.isEmpty || (try? element.select("br").isEmpty()) == false {
                return (cells.isEmpty ? [element] : cells).flatMap { cell in
                    inlineHeaderLines(in: cell).map {
                        SignatureLine(element: element, text: $0.text, startTextNode: $0.startTextNode,
                                      startUTF16Offset: $0.startUTF16Offset, links: $0.links, nonLinkText: $0.nonLinkText)
                    }
                }
            }
            let projected = inlineHeaderLines(in: element).first
            return [SignatureLine(element: element, text: line.text, startTextNode: nil, startUTF16Offset: 0,
                                  links: projected?.links ?? [], nonLinkText: projected?.nonLinkText ?? line.text)]
        }
    }

    static func truncateTrailingContactSignature(in document: Document) throws {
        guard let body = document.body() else { return }
        let lines = signatureLines(in: body)
        guard let lastNonEmpty = lines.indices.last(where: { !lines[$0].text.isEmpty }) else { return }
        var lastContact = lastNonEmpty
        var tailCount = 0
        while !isTrailingSignatureContactLine(lines[lastContact]) {
            guard !isContactSignatureLine(lines[lastContact].text),
                  tailCount < 3, isSignatureTailLine(lines[lastContact].text),
                  let previous = previousNonEmptyLineIndex(before: lastContact, lowerBound: 0, in: lines) else { return }
            tailCount += 1
            lastContact = previous
        }

        let scanStart = max(0, lastNonEmpty - trailingSignatureLookback)
        var contactLineCount = 0
        var fillerCount = 0
        var signatureStart = lastContact
        var strongSupportLineCount = 0
        var signatureSupportLineCount = 0
        var nonEmailContactLineCount = 0
        var sawSignOffBeforeSignature = false
        var precedingBodyLine: String?
        var scanIndex = lastContact

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
                guard isContactSignatureLine(previousText) || linkedContactEvidence(in: lines[previousNonEmptyIndex]) != nil ||
                    isSignatureSupportLine(previousText) ||
                    isLikelySignOffLine(previousText) || isSignatureProductList(previousText) else {
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

            let linkedContact = linkedContactEvidence(in: lines[scanIndex])
            if isContactSignatureLine(text) || linkedContact != nil {
                guard isTrailingSignatureContactLine(lines[scanIndex]) else {
                    precedingBodyLine = text
                    break
                }
                contactLineCount += 1
                if hasNonEmailContactSignal(text) || linkedContact == true {
                    nonEmailContactLineCount += 1
                }
                signatureStart = scanIndex
                scanIndex -= 1
                continue
            }

            if isSignatureProductList(text) {
                // Once the name/title has been reached, a product list above it belongs to the body.
                guard contactLineCount > 0, fillerCount < 3, signatureSupportLineCount == 0 else {
                    precedingBodyLine = text
                    break
                }
                fillerCount += 1
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

        guard contactLineCount >= 2, !isSignatureProductList(lines[signatureStart].text) else { return }

        if hasRepeatedContactRecords(lines[signatureStart...lastNonEmpty].map {
            (text: $0.text, isContact: isTrailingSignatureContactLine($0))
        }) {
            return
        }

        if try shouldPreserveContactTable(
            Array(lines[signatureStart...lastNonEmpty]),
            hasStrongSignal: sawSignOffBeforeSignature || strongSupportLineCount > 0
        ) {
            return
        }

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

        // Widening the range for metadata must not claim unmarked body media,
        // including images between the contacts and footer or inside a footer line.
        if tailCount > 0 {
            for index in signatureStart...lastNonEmpty {
                guard try !containsSignatureTailMedia(lines[index].element) else { return }
            }
        }
        var preservedHTML = ""
        if sawSignOffBeforeSignature {
            if SignatureSignOffPolicy.shouldPreserveNameLine(lines[signatureStart].text),
               !isContactSignatureLine(lines[signatureStart].text), linkedContactEvidence(in: lines[signatureStart]) == nil {
                preservedHTML = "<div>\(escapedHTML(lines[scanIndex].text))<br>\(escapedHTML(lines[signatureStart].text))</div>"
            }
            signatureStart = scanIndex
        }
        // Preserve unmarked media after the signature; only explicit wrappers own their images.
        try removeSignatureLines(lines, from: signatureStart, through: lastNonEmpty, preserving: preservedHTML)
    }

    /// Consecutive name/title/company lines share one record until contact details complete it.
    private static func hasRepeatedContactRecords(_ lines: [(text: String, isContact: Bool)]) -> Bool {
        var hasPendingName = false
        var completedRecords = 0
        for line in lines {
            if line.isContact {
                if hasPendingName {
                    completedRecords += 1
                    if completedRecords > 1 { return true }
                    hasPendingName = false
                }
            } else if isStrongSignatureSupportLine(line.text) ||
                        (looksLikeSignatureNameSupportLine(line.text) && SignatureSignOffPolicy.shouldPreserveNameLine(line.text)) {
                hasPendingName = true
            }
        }
        return false
    }

    /// Column headings and repeated person records distinguish directories from signatures.
    private static func shouldPreserveContactTable(_ lines: [SignatureLine], hasStrongSignal: Bool) throws -> Bool {
        var tables: [Element] = []
        var seenTables = Set<ObjectIdentifier>()
        var cells = Set<ObjectIdentifier>()
        for line in lines where !line.text.isEmpty {
            let element = (line.startTextNode?.parent() as? Element) ?? line.element
            if let table = signatureAncestor(of: element, tags: ["table"]),
               seenTables.insert(ObjectIdentifier(table)).inserted {
                tables.append(table)
            }
            if let cell = signatureAncestor(of: element, tags: ["td", "th"]) {
                cells.insert(ObjectIdentifier(cell))
            }
        }
        // A name, email, and phone in separate columns are insufficient evidence on their own.
        if !hasStrongSignal, cells.count > 1 { return true }

        let fieldHeadings: Set<String> = ["name", "full name", "role", "title", "email", "e-mail", "phone", "telephone"]
        for table in tables {
            var personRows = 0
            for row in try table.select("tr").array() {
                guard signatureAncestor(of: row, tags: ["table"]) === table else { continue }
                let rowCells = row.children().array().filter { ["td", "th"].contains($0.tagNameNormal()) }
                if rowCells.contains(where: { $0.tagNameNormal() == "th" }) { return true }
                // Contact records may use block children instead of BRs, including
                // an unwrapped name before those blocks inside the same cell.
                let cellLines = rowCells.map { inlineHeaderLines(in: $0, splitBlockLines: true) }
                let texts = cellLines.map { lines in
                    lines.map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if texts.filter({ fieldHeadings.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))) }).count >= 2 {
                    return true
                }
                // Also include direct cell names that the signature scan may not project.
                if hasRepeatedContactRecords(cellLines.joined().map {
                    (text: $0.text, isContact: isTrailingSignatureContactLine($0.text) ||
                        linkedContactEvidence(links: $0.links, nonLinkText: $0.nonLinkText) != nil)
                }) { return true }
                // Explicit contact labels such as "Email" and "Telephone" are not person names.
                let nameCandidates = zip(texts, cellLines).compactMap { text, lines in
                    lines.contains(where: { linkedContactEvidence(links: $0.links, nonLinkText: $0.nonLinkText) != nil }) ? nil : text
                } + cellLines.joined().filter {
                    linkedContactEvidence(links: $0.links, nonLinkText: $0.nonLinkText) == nil
                }.map(\.text)
                if nameCandidates.contains(where: { looksLikeSignatureNameSupportLine($0) && SignatureSignOffPolicy.shouldPreserveNameLine($0) }),
                   texts.contains(where: isContactSignatureLine) || cellLines.joined().contains(where: {
                       linkedContactEvidence(links: $0.links, nonLinkText: $0.nonLinkText) != nil
                   }) {
                    personRows += 1
                    if personRows > 1 { return true }
                }
            }
        }
        return false
    }

    private static func signatureAncestor(of element: Element, tags: Set<String>) -> Element? {
        var current: Element? = element
        while let ancestor = current {
            if tags.contains(ancestor.tagNameNormal()) { return ancestor }
            current = ancestor.parent()
        }
        return nil
    }

    /// Trim within a shared block; only remove whole rows when no authored prefix shares that row.
    private static func removeSignatureLines(
        _ lines: [SignatureLine], from start: Int, through end: Int, preserving html: String
    ) throws {
        let first = lines[start]
        // Text embedded in a diagram is part of the media, not a safe signature boundary.
        if let parent = first.startTextNode?.parent() as? Element,
           signatureAncestor(of: parent, tags: ["svg", "video", "audio", "object", "iframe", "canvas"]) != nil {
            return
        }
        // A CID link or background on the boundary's ancestor owns content too.
        var parent = first.startTextNode?.parent() as? Element
        while let element = parent {
            if hasSignatureMediaAttributes(element) { return }
            if element === first.element { break }
            parent = element.parent()
        }
        // Sub-line truncation must preserve the same unmarked trailing media as whole-block cleanup.
        if let boundary = first.startTextNode {
            if try containsMediaAfterSignature(boundary, in: first.element) { return }
        } else if try containsSignatureTailMedia(first.element) {
            return
        }
        var checked = Set<ObjectIdentifier>([ObjectIdentifier(first.element)])
        for line in lines[start...end] where checked.insert(ObjectIdentifier(line.element)).inserted {
            if try containsSignatureTailMedia(line.element) { return }
        }
        // SwiftSoup can reuse an ancestor's raw table HTML after a previously dirty child changes.
        // Reassigning the unchanged tag invalidates that snapshot without changing markup or attributes.
        var invalidatedAncestors = Set<ObjectIdentifier>()
        for line in lines[start...end] {
            var ancestor = line.element.parent()
            while let element = ancestor, element.tagNameNormal() != "body" {
                guard invalidatedAncestors.insert(ObjectIdentifier(element)).inserted else { break }
                try element.tagName(element.tagName())
                ancestor = element.parent()
            }
        }
        let hasPrefix = lines[..<start].contains { $0.element === first.element && !$0.text.isEmpty } ||
            hasMediaBeforeSignature(first.startTextNode, in: first.element)
        if hasPrefix, let node = first.startTextNode {
            try truncateAtTextNode(node, matchStartUTF16: first.startUTF16Offset,
                                   in: node.getWholeText(), stoppingAt: first.element)
            if !html.isEmpty {
                let target = first.element.tagNameNormal() == "tr" ? first.element.children().last() ?? first.element : first.element
                try target.append(html)
            }
        } else {
            if !html.isEmpty {
                if first.element.tagNameNormal() == "tr" {
                    let row = try Element(Tag.valueOf("tr"), first.element.getBaseUri())
                    try row.appendElement("td").html(html)
                    try first.element.before(row)
                } else {
                    try first.element.before(html)
                }
            }
            try first.element.remove()
        }
        var removed = Set<ObjectIdentifier>([ObjectIdentifier(first.element)])
        for index in start...end {
            let element = lines[index].element
            if removed.insert(ObjectIdentifier(element)).inserted { try element.remove() }
        }
    }

    private static func containsMediaAfterSignature(_ boundary: TextNode, in root: Element) throws -> Bool {
        var reachedBoundary = false
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if node === boundary {
                reachedBoundary = true
                continue
            }
            if reachedBoundary, let element = node as? Element {
                if try containsSignatureTailMedia(element) { return true }
                // The subtree was checked as a whole.
                continue
            }
            stack.append(contentsOf: node.getChildNodes().reversed())
        }
        return false
    }

    private static func hasSignatureMediaAttributes(_ element: Element) -> Bool {
        if ["src", "srcset", "background", "poster"].contains(where: element.hasAttr) { return true }
        if ["href", "xlink:href"].contains(where: {
            ((try? element.attr($0)) ?? "").range(of: "cid:", options: .caseInsensitive) != nil
        }) { return true }
        return ((try? element.attr("style")) ?? "").range(
            of: #"url\s*\("#, options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func hasMediaBeforeSignature(_ boundary: TextNode?, in root: Element) -> Bool {
        guard let boundary else { return false }
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if node === boundary { return false }
            if let element = node as? Element {
                if ["img", "picture", "svg", "video", "audio", "object", "embed", "iframe", "canvas"].contains(element.tagNameNormal()) ||
                    hasSignatureMediaAttributes(element) {
                    return true
                }
            }
            stack.append(contentsOf: node.getChildNodes().reversed())
        }
        return false
    }

    /// Contact tokens may have labels or a name, but must not swallow an authored instruction.
    /// Keep the broader contact predicate unchanged for quote/header detection.
    static func isTrailingSignatureContactLine(_ text: String) -> Bool {
        guard isContactSignatureLine(text) else { return false }
        var remainder = text
        var hasLink = false
        for pattern in [signatureEmailPattern, signatureURLPattern].compactMap({ $0 }) {
            let range = NSRange(location: 0, length: remainder.utf16.count)
            if pattern.firstMatch(in: remainder, range: range) != nil {
                hasLink = true
                remainder = pattern.stringByReplacingMatches(in: remainder, range: range, withTemplate: "")
            }
        }
        guard hasLink else {
            return isSignaturePhoneLine(text) || matchesEntireLine(signatureCityStateZipPattern, text: text) ||
                matchesEntireLine(signatureStandaloneContactLabelPattern, text: text) || isSignaturePostalLine(text)
        }
        remainder = remainder.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: #"[<>]"#, with: "", options: .regularExpression)
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>()[]:;,."))
        return remainder.components(separatedBy: CharacterSet(charactersIn: "|•│┃¦")).allSatisfy { segment in
            let label = segment.trimmingCharacters(in: punctuation)
                .replacingOccurrences(of: #"^(?:email|e-mail|website|web|url|tel|phone|e|w|t)\s*:?\s+"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
            return label.isEmpty || ["e", "email", "e-mail", "w", "web", "website", "url"].contains(label.lowercased()) ||
                looksLikeSignatureNameSupportLine(label) || isSignaturePhoneLine(label) ||
                matchesEntireLine(signatureCityStateZipPattern, text: label) ||
                isSignaturePostalLine(label)
        }
    }

    private static let signatureEmailLinkLabelPattern = try? NSRegularExpression(
        pattern: #"^(?:email|e-mail)(?: me| us)?$"#, options: [.caseInsensitive]
    )

    private static let signaturePhoneLinkLabelPattern = try? NSRegularExpression(
        pattern: #"^(?:tel|telephone|phone|call(?: me| us| the office)?)$"#, options: [.caseInsensitive]
    )

    private static let signatureEmailSurroundingLabelPattern = try? NSRegularExpression(
        pattern: #"^(?:email|e-mail|e)$"#, options: [.caseInsensitive]
    )

    private static let signaturePhoneSurroundingLabelPattern = try? NSRegularExpression(
        pattern: #"^(?:tel|telephone|phone|t|office|work|direct|mobile|cell|fax)$"#,
        options: [.caseInsensitive]
    )

    private static let signatureMailtoTargetPattern = try? NSRegularExpression(
        pattern: #"^mailto:([^?]+)(?:\?[^\s]*)?$"#,
        options: [.caseInsensitive]
    )

    private static let signatureLinkedEmailAddressPattern = try? NSRegularExpression(
        pattern: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$"#,
        options: [.caseInsensitive]
    )

    private static let signatureTelTargetPattern = try? NSRegularExpression(
        pattern: #"^tel:\+?[0-9(). -]+$"#, options: [.caseInsensitive]
    )

    private static func isTrailingSignatureContactLine(_ line: SignatureLine) -> Bool {
        isTrailingSignatureContactLine(line.text) || linkedContactEvidence(in: line) != nil
    }

    private static func linkedContactEvidence(in line: SignatureLine) -> Bool? {
        linkedContactEvidence(links: line.links, nonLinkText: line.nonLinkText)
    }

    /// Nil rejects the line; false is email-only evidence; true includes a telephone link.
    /// Targets never enter visible text or the shared quote/header contact predicate.
    private static func linkedContactEvidence(links: [VisibleLineLink], nonLinkText: String) -> Bool? {
        guard !links.isEmpty else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|•│┃¦:;,.()[]–—-"))
        let surrounding = nonLinkText.trimmingCharacters(in: separators)
        let hasEmailLabel = matchesEntireLine(signatureEmailSurroundingLabelPattern, text: surrounding)
        let hasPhoneLabel = matchesEntireLine(signaturePhoneSurroundingLabelPattern, text: surrounding)
        guard surrounding.isEmpty || hasEmailLabel || hasPhoneLabel else { return nil }
        var hasTelephone = false
        for link in links {
            guard link.rawTarget.rangeOfCharacter(from: .newlines) == nil else { return nil }
            if !hasPhoneLabel, isPlausibleSignatureMailtoTarget(link.rawTarget),
               matchesEntireLine(signatureEmailLinkLabelPattern, text: link.text) {
                continue
            }
            if !hasEmailLabel, matchesEntireLine(signatureTelTargetPattern, text: link.rawTarget),
               matchesEntireLine(signaturePhoneLinkLabelPattern, text: link.text),
               (7...15).contains(link.rawTarget.filter { $0.isASCII && $0.isNumber }.count) {
                hasTelephone = true
                continue
            }
            // Every visible anchor must be a contact; a document or instruction link is authored text.
            return nil
        }
        return hasTelephone
    }

    private static func isPlausibleSignatureMailtoTarget(_ target: String) -> Bool {
        let range = NSRange(location: 0, length: target.utf16.count)
        guard let match = signatureMailtoTargetPattern?.firstMatch(in: target, range: range), match.range == range,
              let addressRange = Range(match.range(at: 1), in: target) else { return false }
        let address = String(target[addressRange])
        let localPart = address.prefix(while: { $0 != "@" })
        return !localPart.hasPrefix(".") && !localPart.hasSuffix(".") && !localPart.contains("..") &&
            matchesEntireLine(signatureLinkedEmailAddressPattern, text: address)
    }

    private static func isSignaturePostalLine(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .decimalDigits) != nil &&
            text.range(of: #"^(?:\d|suite\b|ste\b|floor\b|fl\b)"#, options: [.regularExpression, .caseInsensitive]) != nil &&
            signatureAddressPattern?.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    private static func containsSignatureTailMedia(_ element: Element) throws -> Bool {
        let mediaSelector = "img, picture, svg, video, audio, object, embed, iframe, [src], [srcset], [background], [poster]"
        if try !element.select(mediaSelector).isEmpty() { return true }
        // CID references also include linked attachments (href/xlink:href).
        if try element.outerHtml().range(of: "cid:", options: .caseInsensitive) != nil { return true }
        let styledElements = [element] + (try element.select("[style]")).array()
        return styledElements.contains { candidate in
            let style = (try? candidate.attr("style")) ?? ""
            return style.range(of: #"url\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func isSignatureTailLine(_ text: String) -> Bool {
        // Match the entire known boilerplate sentence. A heading or keyword match
        // would also swallow authored discussion or a postscript in the same block.
        if text.range(
            of: #"^(?:(?:confidentiality notice|disclaimer)\s*:\s*)?this e-?mail and any attachments are for the exclusive(?: and confidential)? use of the intended recipients?\.?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        // A whole license/registration identifier is metadata. Sentences containing
        // a number, short slogans, and pipe-separated choices are ambiguous body text.
        guard text.utf16.count <= 160 else { return false }
        return text.range(
            of: #"^(?:(?:licen[cs]e|registration|npn)\b(?:\s+(?:number|no\.?))?\s*[:#]?\s*[A-Z0-9-]*\d[A-Z0-9-]*|licensed in [A-Z]{2}(?:\s*(?:,|&|\band\b)\s*[A-Z]{2})*\s*[-–—]\s*NPN\s*[:#]?\s*\d[\d-]*)\.?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isSignatureProductList(_ text: String) -> Bool {
        let segments = text.components(separatedBy: CharacterSet(charactersIn: "|•"))
        return segments.count >= 3 && segments.allSatisfy { segment in
            let words = segment.split(whereSeparator: \.isWhitespace)
            return (1...3).contains(words.count) && segment.rangeOfCharacter(from: .decimalDigits) == nil &&
                !segment.contains("@") && !segment.contains("http") && !segment.contains("www.") &&
                segment.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?:;")) == nil
        }
    }

    private static func previousNonEmptyLineIndex(
        before index: Int,
        lowerBound: Int,
        in lines: [SignatureLine]
    ) -> Int? {
        guard index > lowerBound else { return nil }

        for candidate in stride(from: index - 1, through: lowerBound, by: -1) {
            if !lines[candidate].text.isEmpty {
                return candidate
            }
        }

        return nil
    }

    /// Internal (not private) because the structural-boundaries pass also uses
    /// it to disambiguate weak header sequences. See `+StructuralBoundaries`.
    static func isContactSignatureLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        if signatureEmailPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if signatureURLPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if isSignaturePhoneLine(text) {
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

    /// Internal (not private) because the structural-boundaries pass calls it
    /// from `+StructuralBoundaries`. Wraps the signature email regex.
    static func containsEmailAddress(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return signatureEmailPattern?.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func hasNonEmailContactSignal(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        if signatureURLPattern?.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        if isSignaturePhoneLine(text) {
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

    private static func isSignaturePhoneLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let slashNormalized = trimmed.replacingOccurrences(
            of: #"\s+/\s+"#,
            with: "|",
            options: .regularExpression
        )
        // A bare whitespace rewrite doubled existing separators and failed the empty-segment guard.
        let normalized = slashNormalized.replacingOccurrences(
            of: #"(?:\s*[|•│┃¦]\s*|\s+)(?=(?:[mcofdtpwh]|tel|telephone|phone|cell|mobile|office|work|home|direct|desk|main|fax)\s*:)"#,
            with: "|",
            options: [.regularExpression, .caseInsensitive]
        )
        let segments = normalized.split(omittingEmptySubsequences: false) { character in
            "|•│┃¦".contains(character)
        }.map { segment in
            String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { return false }

        var foundPhone = false
        var phoneWasLabeled = false
        var requiresClearlyFormattedPhone = false
        for segment in segments {
            if isSignaturePhoneSegment(segment) {
                if requiresClearlyFormattedPhone && !isClearlyFormattedSignaturePhoneSegment(segment) {
                    return false
                }
                if let firstDigit = segment.firstIndex(where: \.isNumber) {
                    let prefix = normalizedSignaturePhonePrefix(String(segment[..<firstDigit]))
                    phoneWasLabeled = phoneWasLabeled || isStandaloneSignaturePhoneLabel(prefix)
                }
                foundPhone = true
                requiresClearlyFormattedPhone = false
                continue
            }

            if foundPhone {
                guard isSignaturePhoneModifier(segment, allowsBusinessHours: phoneWasLabeled) else { return false }
            } else {
                guard isSignaturePhoneLeadingSegment(segment) else { return false }
                if isStandaloneSignaturePhoneLabel(segment) {
                    requiresClearlyFormattedPhone = false
                } else if !isStrongSignatureSupportLine(segment) {
                    requiresClearlyFormattedPhone = true
                }
            }
        }

        return foundPhone
    }

    private static func isSignaturePhoneSegment(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)

        let matches = signaturePhonePattern?.matches(in: text, options: [], range: range) ?? []
        guard let match = matches.first(where: { match in
            guard let candidateRange = Range(match.range, in: text) else { return false }
            let candidate = String(text[candidateRange])
            let digitCount = candidate.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.decimalDigits.contains(scalar) {
                    count += 1
                }
            }
            return digitCount >= 7 && !matchesEntireLine(signatureNonPhoneDatePattern, text: candidate)
        }), let matchRange = Range(match.range, in: text) else {
            return false
        }

        let prefix = normalizedSignaturePhonePrefix(String(text[..<matchRange.lowerBound]))
        let suffix = String(text[matchRange.upperBound...])
        guard isAllowedSignaturePhoneSuffix(suffix) else { return false }

        if prefix.isEmpty {
            return true
        }
        if matchesEntireLine(signaturePhoneKnownLabelPattern, text: prefix) {
            return true
        }
        let compactCandidate = String(text[matchRange]).filter { !$0.isWhitespace }
        return matchesEntireLine(SignaturePatterns.descriptivePhoneLine, text: text) &&
            !matchesEntireLine(signatureNonPhoneDatePattern, text: compactCandidate) &&
            !(matchesEntireLine(signatureBareHoursLabelPattern, text: prefix) &&
                matchesEntireLine(signatureTimeRangePattern, text: compactCandidate))
    }

    private static func isSignaturePhoneLeadingSegment(_ text: String) -> Bool {
        if isStandaloneSignaturePhoneLabel(text) || isStrongSignatureSupportLine(text) {
            return true
        }

        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 2 && looksLikeSignatureNameSupportLine(text)
    }

    private static let signatureBusinessHoursPattern: NSRegularExpression? = {
        let day = #"(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"#
        let time = #"(?:\d{1,2}(?::\d{2})?\s*(?:am|pm))"#
        let dayRange = day + #"\s*[-–—]\s*"# + day
        let timeRange = time + #"\s*[-–—]\s*"# + time
        return try? NSRegularExpression(
            pattern: "^(?:" + dayRange + "(?:\\s+" + timeRange + ")?|" + timeRange + "|24/7)$",
            options: [.caseInsensitive]
        )
    }()

    private static func isSignaturePhoneModifier(_ text: String, allowsBusinessHours: Bool) -> Bool {
        matchesEntireLine(signaturePhoneExtensionPattern, text: text) ||
            matchesEntireLine(signaturePhoneSuffixLabelPattern, text: text) ||
            isStandaloneSignaturePhoneLabel(text) ||
            (allowsBusinessHours && matchesEntireLine(signatureBusinessHoursPattern, text: text))
    }

    private static func isStandaloneSignaturePhoneLabel(_ text: String) -> Bool {
        matchesEntireLine(signaturePhoneKnownLabelPattern, text: text)
    }

    private static func isClearlyFormattedSignaturePhoneSegment(_ text: String) -> Bool {
        if let firstDigit = text.firstIndex(where: \.isNumber) {
            let prefix = normalizedSignaturePhonePrefix(String(text[..<firstDigit]))
            if isStandaloneSignaturePhoneLabel(prefix) {
                return true
            }
        }

        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "+():")) != nil {
            return true
        }

        let separatorCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.whitespaces.contains(scalar) || scalar == "-" || scalar == "." {
                count += 1
            }
        }
        let lowercased = text.lowercased()
        return separatorCount >= 2 || lowercased.contains("ext") || lowercased.contains("x")
    }

    private static func normalizedSignaturePhonePrefix(_ rawPrefix: String) -> String {
        var prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)

        while let last = prefix.last, last == "+" || last == "(" {
            prefix.removeLast()
            prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return prefix
    }

    private static func isAllowedSignaturePhoneSuffix(_ rawSuffix: String) -> Bool {
        var suffix = rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = suffix.first, ".,;".contains(first) {
            suffix.removeFirst()
            suffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !suffix.isEmpty else { return true }

        return matchesEntireLine(signaturePhoneExtensionPattern, text: suffix) ||
            matchesEntireLine(signaturePhoneSuffixLabelPattern, text: suffix)
    }

    private static func matchesEntireLine(_ pattern: NSRegularExpression?, text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return pattern?.firstMatch(in: text, options: [], range: range)?.range == range
    }

    // Shared with the contact-only fallback after DOM text extraction.
    static func isSignatureSupportLine(_ text: String) -> Bool {
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
        SignatureSignOffPolicy.isStrongSupportLine(text)
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
}
