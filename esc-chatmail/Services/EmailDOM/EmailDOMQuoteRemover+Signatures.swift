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
        let raw = SignaturePatterns.legalFooterOpeners + [
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
                    if SignaturePatterns.legalFooterOpeners.contains(pattern.pattern),
                       !isAtSignatureLineStart(textNode) {
                        continue
                    }
                    try truncateAtTextNode(textNode, matchStartUTF16: match.range.location, in: text)
                    return
                }
            }
        }
    }

    private static func isAtSignatureLineStart(_ textNode: TextNode) -> Bool {
        var ancestor = textNode.parent() as? Element
        while let element = ancestor {
            if ["p", "div", "li", "td", "body"].contains(element.tagNameNormal()) {
                return inlineHeaderLines(in: element).contains { $0.startTextNode === textNode }
            }
            ancestor = element.parent()
        }
        return false
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

    private struct SignatureLine {
        let element: Element
        let text: String
        let startTextNode: TextNode?
        let startUTF16Offset: Int
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
                                      startUTF16Offset: $0.startUTF16Offset)
                    }
                }
            }
            return [SignatureLine(element: element, text: line.text, startTextNode: nil, startUTF16Offset: 0)]
        }
    }

    static func truncateTrailingContactSignature(in document: Document) throws {
        guard let body = document.body() else { return }
        let lines = signatureLines(in: body)
        guard let lastNonEmpty = lines.indices.last(where: { !lines[$0].text.isEmpty }) else { return }
        var lastContact = lastNonEmpty
        var tailCount = 0
        while !isContactSignatureLine(lines[lastContact].text) {
            guard tailCount < 3, isSignatureTailLine(lines[lastContact].text),
                  let previous = previousNonEmptyLineIndex(before: lastContact, lowerBound: 0, in: lines) else { return }
            tailCount += 1
            lastContact = previous
        }

        let scanStart = max(0, lastNonEmpty - 32)
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
                guard isContactSignatureLine(previousText) || isSignatureSupportLine(previousText) ||
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

            if isContactSignatureLine(text) {
                contactLineCount += 1
                if hasNonEmailContactSignal(text) {
                    nonEmailContactLineCount += 1
                }
                signatureStart = scanIndex
                scanIndex -= 1
                continue
            }

            if isSignatureProductList(text), contactLineCount > 0, fillerCount < 3 {
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

        // A logo below a confirmed contact block is signature chrome. Bound image-only tails.
        var removalEnd = lastNonEmpty
        var imageCount = 0
        for index in (lastNonEmpty + 1)..<lines.count {
            guard lines[index].text.isEmpty else { break }
            if (try? lines[index].element.select("img").isEmpty()) == false {
                guard imageCount < 3 else { break }
                imageCount += 1
            }
            removalEnd = index
        }
        var preservedHTML = ""
        if sawSignOffBeforeSignature {
            if SignatureSignOffPolicy.shouldPreserveNameLine(lines[signatureStart].text),
               !isContactSignatureLine(lines[signatureStart].text) {
                preservedHTML = "<div>\(escapedHTML(lines[scanIndex].text))<br>\(escapedHTML(lines[signatureStart].text))</div>"
            }
            signatureStart = scanIndex
        }
        try removeSignatureLines(lines, from: signatureStart, through: removalEnd, preserving: preservedHTML)
    }

    /// Trim within a shared block; only remove whole rows when no authored prefix shares that row.
    private static func removeSignatureLines(
        _ lines: [SignatureLine], from start: Int, through end: Int, preserving html: String
    ) throws {
        let first = lines[start]
        // SwiftSoup can reuse an ancestor's raw table HTML after a previously dirty child changes.
        // Reassigning the unchanged tag invalidates that snapshot without changing markup or attributes.
        var ancestor = first.element.parent()
        while let element = ancestor, element.tagNameNormal() != "body" {
            try element.tagName(element.tagName())
            ancestor = element.parent()
        }
        let hasPrefix = lines[..<start].contains { $0.element === first.element && !$0.text.isEmpty }
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

    private static func isSignatureTailLine(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        if text.range(of: #"^(?:licensed|licen[cs]e|registration|registered|npn)\b[^.!?]*\d"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if isSignatureProductList(text) { return true }
        guard text.range(of: #"^(?:p\.?\s*s\.?|please|the|i|we|you|your|also|let|can|could|will)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        return words.count <= 7 && text.rangeOfCharacter(from: .decimalDigits) == nil &&
            text.last.map { ".!".contains($0) } == true
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
        if matchesEntireLine(SignaturePatterns.descriptivePhoneLine, text: text) { return true }
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
        return false
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
