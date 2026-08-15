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

    private static let signatureCityStateZipPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^[A-Z][A-Z .'-]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?$"#,
            options: [.caseInsensitive]
        )
    }()

    private static let signatureStandaloneContactLabelPattern = SignaturePatterns.standaloneContactLabel

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

    static func truncateTrailingContactSignature(in document: Document) throws {
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
        let normalized = slashNormalized.replacingOccurrences(
            of: #"\s+(?=(?:[mcofdtpwh]|tel|telephone|phone|cell|mobile|office|work|home|direct|desk|main|fax)\s*:)"#,
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
        var requiresClearlyFormattedPhone = false
        for segment in segments {
            if isSignaturePhoneSegment(segment) {
                if requiresClearlyFormattedPhone && !isClearlyFormattedSignaturePhoneSegment(segment) {
                    return false
                }
                foundPhone = true
                requiresClearlyFormattedPhone = false
                continue
            }

            if foundPhone {
                guard isSignaturePhoneModifier(segment) else { return false }
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
        return false
    }

    private static func isSignaturePhoneLeadingSegment(_ text: String) -> Bool {
        if isStandaloneSignaturePhoneLabel(text) || isStrongSignatureSupportLine(text) {
            return true
        }

        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 2 && looksLikeSignatureNameSupportLine(text)
    }

    private static func isSignaturePhoneModifier(_ text: String) -> Bool {
        matchesEntireLine(signaturePhoneExtensionPattern, text: text) ||
            matchesEntireLine(signaturePhoneSuffixLabelPattern, text: text) ||
            isStandaloneSignaturePhoneLabel(text)
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
}
