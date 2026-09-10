import Foundation

/// Legacy/plain-text-only fallback for detecting and removing signature blocks.
/// Designed to be conservative for short messages while reliably stripping
/// trailing contact blocks, mobile footers, and legal boilerplate.
enum PlainTextSignatureRemover {
    /// Number of trailing lines to inspect when looking for signature/disclaimer starts.
    /// Corporate signatures can include long compliance footers that exceed 18 lines.
    private static let trailingScanLineLimit = 80

    private struct LineEvaluation {
        let isHardIndicator: Bool
        let isLikelySignatureLine: Bool
        let hasContactInfo: Bool
    }

    // MARK: - Patterns

    private static let hardIndicatorFragments: [String] = [
        // Mobile signatures
        "sent from my iphone",
        "sent from my ipad",
        "sent from my android",
        "sent from outlook",
        "get outlook for",
        "download outlook",
        "sent from mail for windows",
        "sent from samsung",
        "sent from my galaxy",
        "sent from my pixel",
        "sent from spark",
        "sent from protonmail",
        "sent from bluemail",
        "sent from gmail",
        "sent from yahoo mail",
        "sent from my mobile",
        "sent from my phone",
        "sent via ",
        "sent using ",
        "get bluemail for",
        "sent from typeapp",

        // Unsubscribe and preference links
        "unsubscribe",
        "update your email preferences",
        "update your preferences",
        "manage your subscription",
        "click here to unsubscribe",
        "opt out of future",
        "view this email in your browser",
        "having trouble viewing this email",
        "you are receiving this",
        "you received this email because",

        // Legal disclaimers
        "notice to recipient:",
        "this email and any attachments",
        "this message is intended",
        "this e-mail is meant for only the intended recipient",
        "this communication is confidential",
        "this communication is provided for informational purposes",
        "our form crs",
        "this message contains confidential",
        "this e-mail is confidential",
        "this electronic mail transmission may contain confidential",
        "the information in this email",
        "if you are not the intended recipient",
        "if you received this e-mail in error",
        "if you have received this email in error",
        "if you believe you have received this message in error",
        "for additional policies governing this e-mail",
        "confidentiality notice:",
        "disclaimer:",
        "legal disclaimer:",
        "please consider the environment",
        "think before you print",

        // Social / footer links
        "follow us on",
        "connect with us",
        "join us on",
        "find us on",
        "visit our website",
        "privacy policy",
        "terms of service",
        "copyright ©",
        "© 20",

        // Marketing boilerplate
        "forward to a friend",
        "share this email",
        "reply stop to unsubscribe",

        // Wire fraud warnings (real estate)
        "*wire fraud",
        "wire fraud is real",
        "before wiring any money",
    ]

    // A legal opener does not make later paragraphs boilerplate. Recognise known
    // disclaimer sentence forms instead of words such as "account" or "services".
    private static let legalContinuationPrefixes: [String] = [
        "please refer to your monthly statements for the official record",
        "questions should be directed to your",
        "you should consult your own tax, legal, and accounting advisors",
        "please submit personal information through secure channels",
        "investment products involve risk",
        "no bank guarantee is provided for investment products",
        "this material is intended solely for the recipient",
        "distribution to unintended recipients is restricted",
        "any forwarding should comply with firm communication standards",
        "payment details should always be confirmed by phone using a known number",
        "if funds were sent to an unintended account",
        "additional disclosures may apply based on account type",
        "product availability depends on review and approval requirements",
        "services described may vary by location and client eligibility",
        "historical references do not guarantee future performance",
        "terms may be updated periodically without prior notice",
        "use of electronic communication is subject to monitoring and retention",
        "this message may include privileged information under applicable law",
    ]

    private static let signOffWords = SignaturePatterns.signOffPhrases

    private static let delimiterLinePattern = SignaturePatterns.delimiterLine

    private static let contactPrefixPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:[mcofdtp](?:\s*:\s*|\s+)|(?:tel|phone|mobile|office|direct|fax)(?:[.:]\s+|\s+))\(?\+?\d[\d\s().-]{5,}\b"#,
            options: [.caseInsensitive]
        )
    }()

    private static let standaloneContactLabelPattern = SignaturePatterns.standaloneContactLabel

    private static let emailPattern = EmailPatterns.address

    private static let urlPattern = URLPatterns.webURL

    private static let phonePattern = SignaturePatterns.phone

    private static let titleKeywords: [String] = [
        "director", "manager", "vp", "vice president", "president", "founder",
        "ceo", "cfo", "cto", "coo", "realtor", "broker", "associate",
        "sales", "agent", "partner", "principal", "owner"
    ]

    private static let addressKeywords: [String] = [
        "street", "st.", "st ", "avenue", "ave", "ave.", "road", "rd", "rd.",
        "boulevard", "blvd", "blvd.", "lane", "ln", "ln.", "drive", "dr", "dr.",
        "suite", "ste", "ste.", "floor", "fl", "fl."
    ]

    /// Address keywords must be matched on word boundaries.
    /// Avoid substring false positives like matching "ave" inside "have".
    private static let addressKeywordPattern = SignaturePatterns.addressKeyword

    private static let organizationKeywords: [String] = [
        " inc", " inc.", " llc", " ltd", " corp", " corp.", " corporation",
        " company", " co.", " partners", " group"
    ]

    private static let singleNamePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^[A-Z][A-Za-z'\\-]{1,31}$", options: [])
    }()
    private static let multiWordNamePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^[A-Z][A-Za-z'.\\-]{1,31}(?:\\s+[A-Z][A-Za-z'.\\-]{1,31}){1,3}$", options: [])
    }()

    // MARK: - Public API

    static func removeSignature(from text: String) -> String {
        let normalized = TextProcessing.normalizeLineEndings(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return trimmed }

        var lastNonEmpty = lines.count - 1
        while lastNonEmpty >= 0 && lines[lastNonEmpty].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastNonEmpty -= 1
        }
        guard lastNonEmpty >= 0 else { return "" }

        if preservesPostscriptAfterSignOff(lines: lines, lastNonEmpty: lastNonEmpty) {
            return trimmed
        }

        let scanStart = max(0, lastNonEmpty - trailingScanLineLimit)
        // Pass 1: Look for definitive signature indicators near the end.
        var earliestHardIndicator: Int?
        for index in stride(from: lastNonEmpty, through: scanStart, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let evaluation = evaluateLine(line)
            if evaluation.isHardIndicator && hasSignatureOnlyTail(after: index, lines: lines, lastNonEmpty: lastNonEmpty) {
                earliestHardIndicator = index
            }
        }
        if let hardIndicatorIndex = earliestHardIndicator {
            let hardIndicatorLine = lines[hardIndicatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if isDelimiterLine(hardIndicatorLine) {
                return joinLines(lines, upTo: hardIndicatorIndex)
            }
            let startLine = findSignatureStartLine(before: hardIndicatorIndex, lines: lines)
            return joinLines(lines, upTo: preservingSignOff(startingAt: startLine, through: hardIndicatorIndex, lines: lines))
        }

        // Pass 2 is end-anchored: a body sentence or bare sign-off after contact
        // information must never be consumed as part of a signature.
        guard evaluateLine(lines[lastNonEmpty]).hasContactInfo else {
            // A clipped corporate row can still identify itself by expanding the
            // standalone name immediately above it, without treating arbitrary titles as tails.
            if containsSignatureSeparator(lines[lastNonEmpty]),
               let nameIndex = previousNonEmptyLineIndex(before: lastNonEmpty, in: lines),
               shouldPreserveSingleNameSignOff(lines[nameIndex], at: nameIndex, in: lines) {
                return joinLines(lines, upTo: nameIndex + 1)
            }
            return trimmed
        }

        // Pass 2: Heuristic trailing block detection (contact info or titles).
        var signatureStartLine: Int?
        var signatureLineCount = 0
        var contactSignals = 0
        var signatureSupportSignals = 0
        var affiliationSupportSignals = 0
        var sawSignOffLine = false
        var bridgedTagline = false
        var sawSeparator = false

        for index in stride(from: lastNonEmpty, through: scanStart, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                if !bridgedTagline, contactSignals >= 2,
                   let previous = previousNonEmptyLineIndex(before: index, in: lines),
                   isTaglineBetweenAffiliationAndContacts(lines[previous], at: previous, lines: lines) {
                    continue
                }
                if shouldContinueAcrossBlankLine(
                    at: index,
                    scanStart: scanStart,
                    lines: lines,
                    signatureLineCount: signatureLineCount,
                    signatureSupportSignals: signatureSupportSignals
                ) {
                    signatureStartLine = index
                    sawSeparator = true
                    continue
                }
                if signatureLineCount >= 2 && (contactSignals > 0 || sawSeparator) {
                    signatureStartLine = index
                    break
                }
                sawSeparator = true
                continue
            }

            let isTaglineBridge = !bridgedTagline && contactSignals >= 2 &&
                isTaglineBetweenAffiliationAndContacts(line, at: index, lines: lines)
            if isBodyProseLine(line) && !isTaglineBridge { break }
            let evaluation = evaluateLine(line)
            if evaluation.hasContactInfo {
                contactSignals += 1
            }

            // Preserve a standalone first-name sign-off above a separated signature block:
            // "Jasmine" + blank line + "Jasmine Lastname | Title".
            if signatureLineCount > 0 &&
                sawSeparator &&
                signatureSupportSignals > 0 &&
                shouldPreserveSingleNameSignOff(line, at: index, in: lines) {
                break
            }

            if isTaglineBridge { bridgedTagline = true }
            let isContinuationLine = signatureLineCount > 0 && (isLikelySignatureContinuation(line) || isTaglineBridge)
            if evaluation.isLikelySignatureLine || isContinuationLine {
                signatureLineCount += 1
                // We scan backwards, so each matched line becomes the new earliest start.
                signatureStartLine = index
                if isSignOffLineForSignatureContext(line) {
                    sawSignOffLine = true
                }
                if hasAffiliationSignatureSignal(line, evaluation: evaluation) {
                    affiliationSupportSignals += 1
                }
                if hasStrongSignatureSignal(line, evaluation: evaluation) {
                    signatureSupportSignals += 1
                }
            } else if signatureLineCount > 0 {
                if isSignOffLineForSignatureContext(line) {
                    sawSignOffLine = true
                }
                break
            }
        }

        if let startLine = signatureStartLine {
            if contactSignals == 0 &&
                signatureSupportSignals == 0 &&
                hasBodyLikeContentAfterPotentialSignOff(startingAt: startLine, lines: lines, lastNonEmpty: lastNonEmpty) {
                return trimmed
            }
            if contactSignals >= 2 &&
                hasContactListIntroBeforeSignature(startingAt: startLine, lines: lines) {
                return trimmed
            }
            guard signatureLineCount >= 3,
                  contactSignals >= 2 || (contactSignals == 1 && (affiliationSupportSignals > 0 || sawSignOffLine)),
                  sawSignOffLine || affiliationSupportSignals > 0 ||
                    lines[startLine...lastNonEmpty].contains(where: { matchesRegex(multiWordNamePattern, in: $0) }) else {
                return trimmed
            }
            let adjustedStart = adjustToSeparator(startLine, lines: lines)
            return joinLines(lines, upTo: preservingSignOff(startingAt: adjustedStart, through: lastNonEmpty, lines: lines))
        }

        return trimmed
    }

    /// A marker inside a reply is not a footer when ordinary body text follows it.
    /// Soft-wrapped legal paragraphs may continue onto a lowercase line without a
    /// paragraph break; a later body paragraph must still stop the truncation.
    private static func hasSignatureOnlyTail(after index: Int, lines: [String], lastNonEmpty: Int) -> Bool {
        if isDelimiterLine(lines[index].trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
        guard index < lastNonEmpty else { return true }
        var previous = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let isLegalFooter = previous.range(of: #"confidential|disclaimer|notice to recipient|communication.*informational|our form crs|wire fraud"#, options: [.regularExpression, .caseInsensitive]) != nil
        let isCIDFooter = previous.lowercased().hasPrefix("[cid:") &&
            lines.prefix(index).suffix(5).contains(where: SignatureSignOffPolicy.isStrongSupportLine)
        var cidTailLines = 0
        for candidate in lines[(index + 1)...lastNonEmpty] {
            let line = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { previous = ""; continue }
            let evaluation = evaluateLine(line)
            let continuesWrappedFooter = isLegalFooter && !hasAuthoredProsePrefix(line) && !previous.isEmpty &&
                !(previous.last.map { ".!?".contains($0) } ?? false) && line.first?.isLowercase == true
            let isLegalContinuation = isLegalFooter && legalContinuationPrefixes.contains {
                line.lowercased().hasPrefix($0)
            }
            let isCIDTagline = isCIDFooter && !hasAuthoredProsePrefix(line) &&
                !isPostscriptLine(line.lowercased()) && cidTailLines < 2 && line.count <= 72 &&
                line.rangeOfCharacter(from: .decimalDigits) == nil &&
                !(line.last.map { ".!?".contains($0) } ?? false)
            if isCIDTagline { cidTailLines += 1 }
            guard evaluation.isHardIndicator || isStrictContactLine(line) ||
                    isStrictSupportLine(line) || continuesWrappedFooter ||
                    isLegalContinuation || isCIDTagline else { return false }
            previous = line
        }
        return true
    }

    /// Preserve the same sign-off/name pair as the HTML wrapper cleanup.
    private static func preservingSignOff(startingAt start: Int, through end: Int, lines: [String]) -> Int {
        var start = start
        if let previous = previousNonEmptyLineIndex(before: start, in: lines),
           isSignOffLineForSignatureContext(lines[previous]),
           let first = lines[start...end].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
           SignatureSignOffPolicy.shouldPreserveNameLine(first) { start = previous }
        guard start <= end else { return start }
        for index in start...end where isSignOffLineForSignatureContext(lines[index]) {
            var nameIndex = index + 1
            while nameIndex <= end && lines[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nameIndex += 1
            }
            guard nameIndex <= end else { return start }
            let name = lines[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if SignatureSignOffPolicy.shouldPreserveNameLine(name) {
                return nameIndex + 1
            }
            return start
        }
        return start
    }

    private static func isTaglineBetweenAffiliationAndContacts(_ line: String, at index: Int, lines: [String]) -> Bool {
        guard !hasAuthoredProsePrefix(line), !isPostscriptLine(line.lowercased()),
              line.count <= 100, line.split(whereSeparator: \.isWhitespace).count <= 7,
              line.last == "." || line.last == "!",
              line.rangeOfCharacter(from: .decimalDigits) == nil,
              let previousIndex = previousNonEmptyLineIndex(before: index, in: lines) else { return false }
        let previous = lines[previousIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return SignatureSignOffPolicy.isStrongSupportLine(previous) ||
            matchesRegex(multiWordNamePattern, in: previous)
    }

    private static func hasAuthoredProsePrefix(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:please|kindly|can|could|would|i|we|you|our|the|this|that|here|there|let|remember|also|attached|send|call|reply|note|use|check|review|confirm)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isBodyProseLine(_ line: String) -> Bool {
        if isSignOffLineForSignatureContext(line) { return false }
        if hasAuthoredProsePrefix(line) || isPostscriptLine(line.lowercased()) { return true }
        return line.split(whereSeparator: \.isWhitespace).count > 1 &&
            (line.last.map { ".!?".contains($0) } ?? false) &&
            !SignatureSignOffPolicy.isStrongSupportLine(line) &&
            line.range(of: #"\b(?:n\.a|ltd|llp)\.$"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func isStrictSupportLine(_ line: String) -> Bool {
        guard !isBodyProseLine(line) else { return false }
        return SignatureSignOffPolicy.isStrongSupportLine(line) ||
            matchesRegex(singleNamePattern, in: line) || matchesRegex(multiWordNamePattern, in: line) ||
            isSignOffLineForSignatureContext(line)
    }

    /// Email/URL matches alone are not contact rows: validate the text left around them.
    private static func isStrictContactLine(_ line: String) -> Bool {
        guard !isBodyProseLine(line) else { return false }
        if matchesRegex(standaloneContactLabelPattern, in: line) ||
            matchesRegex(SignaturePatterns.descriptivePhoneLine, in: line) { return true }
        let patterns = [emailPattern, urlPattern, phonePattern]
        guard patterns.contains(where: { matchesRegex($0, in: line) }) else { return false }
        var remainder = line
        for pattern in patterns {
            remainder = pattern?.stringByReplacingMatches(
                in: remainder, range: NSRange(location: 0, length: remainder.utf16.count), withTemplate: " "
            ) ?? remainder
        }
        remainder = remainder.replacingOccurrences(of: #"[|•│┃¦<>():+.,/\-]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty || matchesRegex(standaloneContactLabelPattern, in: remainder) ||
            remainder.range(of: #"^(?:tel|phone|mobile|office|direct|fax|cell)$"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            isStrictSupportLine(remainder)
    }

    // MARK: - Line Evaluation

    private static func evaluateLine(_ line: String) -> LineEvaluation {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let isDelimiter = matchesRegex(delimiterLinePattern, in: trimmed)
        let isCidLine = lowercased.hasPrefix("[cid:")
        let hasLegalOpener = SignaturePatterns.legalFooterOpeners.contains {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let hasHardFragment = hasLegalOpener || hardIndicatorFragments.contains { fragment in
            lowercased.hasPrefix(fragment) ||
                lowercased.range(of: #"[.!?]\s+"# + NSRegularExpression.escapedPattern(for: fragment), options: .regularExpression) != nil
        }
        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed) ||
            matchesRegex(SignaturePatterns.descriptivePhoneLine, in: trimmed)
        let hasStandaloneContactLabel = matchesRegex(standaloneContactLabelPattern, in: trimmed)

        let hasEmail = matchesRegex(emailPattern, in: trimmed)
        let hasUrl = matchesRegex(urlPattern, in: trimmed)
        let hasPhoneCandidate = matchesRegex(phonePattern, in: trimmed)
        // Phone numbers are common in the BODY of short emails ("call me at ...").
        // Only treat a phone number as signature contact info if the line itself is
        // primarily a phone line (or uses an explicit prefix like "T:", handled above).
        let hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased: lowercased)

        let hasContactInfo = hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone || hasStandaloneContactLabel

        // Keep hard indicators conservative. URL/phone lines need surrounding context.
        let isHardIndicator = isDelimiter || isCidLine || hasHardFragment

        var score = 0
        if isSignOffLine(lowercased) { score += 1 }
        if hasContactInfo { score += 3 }
        if containsKeyword(lowercased, in: titleKeywords) { score += 1 }
        if containsAddressKeyword(lowercased) { score += 1 }
        if trimmed.count <= 72 { score += 1 }
        if containsSignatureSeparator(trimmed) { score += 1 }

        if looksLikeSentence(trimmed) { score -= 1 }
        if TextProcessing.isListItem(trimmed) { score -= 2 }

        let isLikelySignatureLine = score >= 2

        return LineEvaluation(
            isHardIndicator: isHardIndicator,
            isLikelySignatureLine: isLikelySignatureLine,
            hasContactInfo: hasContactInfo
        )
    }

    private static func looksLikeStandalonePhoneLine(_ trimmed: String, lowercased: String) -> Bool {
        // Be conservative: only match lines that are basically a phone number.
        // Examples:
        // - "415-314-9804"
        // - "+1 (415) 314-9804"
        // Avoid treating sentences like "Feel free to call me at 415-314-9804." as signature lines.
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

        guard digits >= 7 else { return false }
        guard trimmed.count <= 40 else { return false }

        if letters == 0 {
            return true
        }

        // Allow a tiny amount of letters for extension markers (e.g., "ext", "x").
        if letters <= 3 {
            if lowercased.contains("ext") || lowercased.contains(" x") || lowercased.hasSuffix("x") {
                return true
            }
        }

        return false
    }

    private static func isSignOffLine(_ lowercased: String) -> Bool {
        let normalized = lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
        for signOff in signOffWords {
            if normalized == signOff || normalized == "\(signOff)," {
                return true
            }
        }
        return false
    }

    private static func isSignOffLineForSignatureContext(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return signOffWords.contains(normalized)
    }

    private static func looksLikeSentence(_ line: String) -> Bool {
        guard line.count > 40 else { return false }
        return line.hasSuffix(".") || line.hasSuffix("!") || line.hasSuffix("?")
    }

    private static func containsKeyword(_ text: String, in keywords: [String]) -> Bool {
        return keywords.contains { text.contains($0) }
    }

    private static func containsAddressKeyword(_ lowercased: String) -> Bool {
        guard let regex = addressKeywordPattern else {
            // Fallback to previous substring behavior if regex compilation fails.
            return containsKeyword(lowercased, in: addressKeywords)
        }
        let range = NSRange(location: 0, length: lowercased.utf16.count)
        return regex.firstMatch(in: lowercased, options: [], range: range) != nil
    }

    private static func containsSignatureSeparator(_ text: String) -> Bool {
        text.contains("|") || text.contains("│") || text.contains("┃") || text.contains("¦")
    }

    // MARK: - Signature Range Helpers

    private static func findSignatureStartLine(before indicatorIndex: Int, lines: [String]) -> Int {
        var foundShortLines = false
        var signatureStartLine: Int?

        let upperBound = min(indicatorIndex - 1, lines.count - 1)
        guard upperBound >= 0 else { return indicatorIndex }

        for index in stride(from: upperBound, through: 0, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                if foundShortLines {
                    if shouldContinueAcrossBlankLineInHardIndicatorScan(at: index, lines: lines) {
                        signatureStartLine = index
                        continue
                    }
                    signatureStartLine = index
                    break
                }
                continue
            }

            if isBodyProseLine(line) { break }
            let evaluation = evaluateLine(line)
            if !foundShortLines,
               shouldPreserveSingleNameSignOff(line, at: index, in: lines) {
                break
            }
            if foundShortLines,
               shouldPreserveSingleNameSignOff(line, at: index, in: lines) {
                break
            }

            // When we find a hard indicator (like "M:"), we want to walk upward and include
            // adjacent signature lines. Some corporate signature lines can be very long, so
            // prefer the scoring-based heuristic (`isLikelySignatureLine`) over the older
            // short-line heuristic.
            if evaluation.isHardIndicator || evaluation.isLikelySignatureLine || looksLikeSignatureLine(line) {
                foundShortLines = true
            } else {
                break
            }
        }

        return signatureStartLine ?? indicatorIndex
    }

    private static func shouldContinueAcrossBlankLineInHardIndicatorScan(
        at index: Int,
        lines: [String]
    ) -> Bool {
        var probe = index - 1
        var blankLinesSeen = 0

        while probe >= 0 {
            let candidate = lines[probe].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty {
                blankLinesSeen += 1
                if blankLinesSeen > 1 {
                    return false
                }
                probe -= 1
                continue
            }

            if shouldPreserveSingleNameSignOff(candidate, at: probe, in: lines) {
                return true
            }

            if isBodyProseLine(candidate) { return false }
            let evaluation = evaluateLine(candidate)
            if evaluation.isHardIndicator ||
                evaluation.hasContactInfo ||
                evaluation.isLikelySignatureLine ||
                isLikelySignatureContinuation(candidate) {
                return true
            }

            return false
        }

        return false
    }

    private static func adjustToSeparator(_ startLine: Int, lines: [String]) -> Int {
        let previousIndex = startLine - 1
        if previousIndex >= 0 {
            let previousLine = lines[previousIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if previousLine.isEmpty {
                return previousIndex
            }
        }
        return startLine
    }

    private static func looksLikeSignatureLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if TextProcessing.isListItem(trimmed) { return false }

        let shortEnough = trimmed.count <= 80
        let noSentenceEnding = !(trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))
        let lowercased = trimmed.lowercased()
        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed) ||
            matchesRegex(SignaturePatterns.descriptivePhoneLine, in: trimmed)
        let hasStandaloneContactLabel = matchesRegex(standaloneContactLabelPattern, in: trimmed)
        let hasEmail = matchesRegex(emailPattern, in: trimmed)
        let hasUrl = matchesRegex(urlPattern, in: trimmed)
        let hasPhoneCandidate = matchesRegex(phonePattern, in: trimmed)
        let hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased: lowercased)

        if hasContactPrefix || hasStandaloneContactLabel || hasEmail || hasUrl || hasStandalonePhone {
            return true
        }

        if containsKeyword(lowercased, in: organizationKeywords) {
            return true
        }

        return shortEnough && (noSentenceEnding || trimmed.hasSuffix(","))
    }

    /// Preserve single first-name sign-offs ("Jasmine") when they are part of body content
    /// and not attached to explicit sign-off markers like "Thanks,".
    private static func shouldPreserveSingleNameSignOff(_ line: String, at index: Int, in lines: [String]) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matchesRegex(singleNamePattern, in: trimmed) else { return false }

        // If the line below already looks like signature content, only preserve this single
        // name when the next signature line expands the same name (e.g., "Jasmine" followed
        // by "Jasmine Lastname | Title").
        let lowercasedTrimmed = trimmed.lowercased()
        if let nextNonEmptyLine = nextNonEmptyLine(after: index, in: lines) {
            let nextEvaluation = evaluateLine(nextNonEmptyLine)
            let hasSignatureContextBelow =
                nextEvaluation.hasContactInfo ||
                nextEvaluation.isHardIndicator ||
                nextEvaluation.isLikelySignatureLine ||
                isLikelySignatureContinuation(nextNonEmptyLine)

            if hasSignatureContextBelow {
                let normalizedNext = nextNonEmptyLine
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let expandsSameName = normalizedNext.hasPrefix("\(lowercasedTrimmed) ")
                if !expandsSameName {
                    return false
                }
            }
        }

        var previousIndex = index - 1
        while previousIndex >= 0 {
            let previous = lines[previousIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if previous.isEmpty {
                previousIndex -= 1
                continue
            }

            let previousLowercased = previous.lowercased()
            if isSignOffLine(previousLowercased) {
                return false
            }

            // If the line above the candidate already looks like signature content
            // (name/contact/title/org/address), treat this as part of the signature
            // rather than preserving it as a standalone first-name sign-off.
            let previousEvaluation = evaluateLine(previous)
            if previousEvaluation.hasContactInfo ||
                previousEvaluation.isHardIndicator ||
                previousEvaluation.isLikelySignatureLine ||
                isLikelySignatureContinuation(previous) {
                return false
            }

            return true
        }

        return true
    }

    private static func nextNonEmptyLine(after index: Int, in lines: [String]) -> String? {
        var probe = index + 1
        while probe < lines.count {
            let candidate = lines[probe].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
            probe += 1
        }
        return nil
    }

    private static func hasContactListIntroBeforeSignature(startingAt startLine: Int, lines: [String]) -> Bool {
        guard let previousIndex = previousNonEmptyLineIndex(before: startLine, in: lines) else {
            return false
        }
        return isContactListIntroLine(lines[previousIndex])
    }

    private static let contactListIntroKeywords: [String] = [
        "contact", "email", "reviewer", "recipient"
    ]

    private static func isContactListIntroLine(_ line: String) -> Bool {
        let lowercased = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return lowercased.hasSuffix(":") &&
            contactListIntroKeywords.contains(where: { lowercased.contains($0) })
    }

    private static func preservesPostscriptAfterSignOff(lines: [String], lastNonEmpty: Int) -> Bool {
        guard isPostscriptLine(lines[lastNonEmpty].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return false
        }

        guard let nameIndex = previousNonEmptyLineIndex(before: lastNonEmpty, in: lines),
              let signOffIndex = previousNonEmptyLineIndex(before: nameIndex, in: lines) else {
            return false
        }

        let nameLine = lines[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let signOffLine = lines[signOffIndex].trimmingCharacters(in: .whitespacesAndNewlines)

        let isNameLine =
            matchesRegex(singleNamePattern, in: nameLine) ||
            matchesRegex(multiWordNamePattern, in: nameLine)

        return isNameLine && isSignOffLine(signOffLine.lowercased())
    }

    private static func hasBodyLikeContentAfterPotentialSignOff(
        startingAt startLine: Int,
        lines: [String],
        lastNonEmpty: Int
    ) -> Bool {
        var sawSignOffLikeLine = false

        for index in startLine...lastNonEmpty {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let lowercased = line.lowercased()
            let isNameLine =
                matchesRegex(singleNamePattern, in: line) ||
                matchesRegex(multiWordNamePattern, in: line)
            let isPotentialSignOffLine =
                isSignOffLine(lowercased) ||
                isNameLine ||
                isDelimiterLine(line)

            if isPotentialSignOffLine {
                sawSignOffLikeLine = true
                continue
            }

            guard sawSignOffLikeLine else { return false }

            if isPostscriptLine(lowercased) {
                return true
            }

            let evaluation = evaluateLine(line)
            return !evaluation.isHardIndicator &&
                !evaluation.hasContactInfo &&
                !evaluation.isLikelySignatureLine &&
                !isLikelySignatureContinuation(line)
        }

        return false
    }

    private static func previousNonEmptyLineIndex(before index: Int, in lines: [String]) -> Int? {
        var probe = index - 1
        while probe >= 0 {
            if !lines[probe].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return probe
            }
            probe -= 1
        }
        return nil
    }

    private static func isPostscriptLine(_ lowercased: String) -> Bool {
        let trimmed = lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("p.s.") ||
            trimmed.hasPrefix("p.s:") ||
            trimmed.hasPrefix("ps.") ||
            trimmed.hasPrefix("ps:")
    }

    private static func shouldContinueAcrossBlankLine(
        at index: Int,
        scanStart: Int,
        lines: [String],
        signatureLineCount: Int,
        signatureSupportSignals: Int
    ) -> Bool {
        guard signatureLineCount > 0 else { return false }

        var probe = index - 1
        var blankLinesSeen = 0
        while probe >= scanStart {
            let candidate = lines[probe].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty {
                blankLinesSeen += 1
                if blankLinesSeen > 1 {
                    return false
                }
                probe -= 1
                continue
            }

            if signatureSupportSignals > 0 &&
                shouldPreserveSingleNameSignOff(candidate, at: probe, in: lines) {
                return true
            }

            let evaluation = evaluateLine(candidate)
            if evaluation.isLikelySignatureLine ||
                evaluation.hasContactInfo ||
                hasStrongSignatureSignal(candidate, evaluation: evaluation) ||
                isLikelySignatureContinuation(candidate) {
                return true
            }

            return false
        }

        return false
    }

    private static func isLikelySignatureContinuation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if TextProcessing.isListItem(trimmed) { return false }

        let lowercased = trimmed.lowercased()
        if isSignOffLine(lowercased) { return true }
        if matchesRegex(singleNamePattern, in: trimmed) || matchesRegex(multiWordNamePattern, in: trimmed) {
            return true
        }
        if containsKeyword(lowercased, in: titleKeywords) ||
            containsKeyword(lowercased, in: organizationKeywords) ||
            containsAddressKeyword(lowercased) {
            return true
        }
        if containsSignatureSeparator(trimmed) {
            return true
        }

        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed) ||
            matchesRegex(SignaturePatterns.descriptivePhoneLine, in: trimmed)
        let hasEmail = matchesRegex(emailPattern, in: trimmed)
        let hasUrl = matchesRegex(urlPattern, in: trimmed)
        let hasPhoneCandidate = matchesRegex(phonePattern, in: trimmed)
        let hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased: lowercased)
        if hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone {
            return true
        }

        // A real city/state/postal row can continue an already corroborated block.
        // A comma and arbitrary digits (calendar dates, meeting IDs) cannot.
        if trimmed.range(of: #"^[A-Za-z][A-Za-z .'-]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func hasStrongSignatureSignal(_ line: String, evaluation: LineEvaluation) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowercased = trimmed.lowercased()
        if evaluation.hasContactInfo || evaluation.isHardIndicator {
            return true
        }
        if containsSignatureSeparator(trimmed) {
            return true
        }
        if containsKeyword(lowercased, in: titleKeywords) ||
            containsKeyword(lowercased, in: organizationKeywords) ||
            containsAddressKeyword(lowercased) {
            return true
        }

        return false
    }

    private static func hasAffiliationSignatureSignal(_ line: String, evaluation: LineEvaluation) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowercased = trimmed.lowercased()
        if containsSignatureSeparator(trimmed) {
            return true
        }
        if containsKeyword(lowercased, in: titleKeywords) ||
            containsKeyword(lowercased, in: organizationKeywords) ||
            containsAddressKeyword(lowercased) {
            return true
        }
        if evaluation.isHardIndicator && !evaluation.hasContactInfo {
            return true
        }

        return false
    }

    // MARK: - Utilities

    private static func joinLines(_ lines: [String], upTo endLine: Int) -> String {
        let endIndex = max(0, min(endLine, lines.count))
        let joined = lines[0..<endIndex].joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesRegex(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func isDelimiterLine(_ line: String) -> Bool {
        matchesRegex(delimiterLinePattern, in: line)
    }
}
