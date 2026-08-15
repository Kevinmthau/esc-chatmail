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

    private static let signaturePhonePattern = SignaturePatterns.phone

    private static let signaturePhonePrefixPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:m|c|o|f|d|t|p|tel|phone|cell|mobile|office|direct|fax)\s*[:.-]?\s*\(?\+?\d[\d\s().-]{5,}\b"#,
            options: [.caseInsensitive]
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
        let range = NSRange(location: 0, length: trimmed.utf16.count)

        if signaturePhonePrefixPattern?.firstMatch(in: trimmed, options: [], range: range) != nil {
            return true
        }
        guard signaturePhonePattern?.firstMatch(in: trimmed, options: [], range: range) != nil else {
            return false
        }

        // Phone numbers are common in authored prose ("call me at ..."). Only
        // treat an unlabeled number as signature data when the line is mostly
        // the number itself, while retaining short extension markers.
        let lowercase = trimmed.lowercased()
        let letters = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        let digits = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.decimalDigits.contains(scalar) {
                count += 1
            }
        }

        guard digits >= 7, trimmed.count <= 40 else { return false }
        guard letters > 0 else { return true }

        return letters <= 3 && (
            lowercase.contains("ext") ||
            lowercase.contains(" x") ||
            lowercase.hasSuffix("x")
        )
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
