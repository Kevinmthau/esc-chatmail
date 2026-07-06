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
        "important:",
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

    private static let signOffWords: Set<String> = [
        "regards",
        "thanks",
        "thank you",
        "best",
        "cheers",
        "sincerely",
        "yours truly",
        "best wishes",
        "best regards",
        "kind regards",
        "warm regards",
        "take care",
        "all the best"
    ]

    private static let delimiterLinePattern = SignaturePatterns.delimiterLine

    private static let contactPrefixPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^(m|c|o|f|d|t|p|tel|phone|mobile|office|direct|fax)\\s*(?:[:.-]\\s*\\S+|\\(?\\+?\\d[\\d\\s().-]{5,}\\b)",
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
        let nonEmptyLineCount = lines.reduce(into: 0) { count, line in
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }

        // Pass 1: Look for definitive signature indicators near the end.
        var earliestHardIndicator: Int?
        for index in stride(from: lastNonEmpty, through: scanStart, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let evaluation = evaluateLine(line)
            if evaluation.isHardIndicator {
                earliestHardIndicator = index
            }
        }
        if let hardIndicatorIndex = earliestHardIndicator {
            let hardIndicatorLine = lines[hardIndicatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if isDelimiterLine(hardIndicatorLine) {
                return joinLines(lines, upTo: hardIndicatorIndex)
            }
            let startLine = findSignatureStartLine(before: hardIndicatorIndex, lines: lines)
            return joinLines(lines, upTo: startLine)
        }

        // Pass 2: Heuristic trailing block detection (contact info or titles).
        var signatureStartLine: Int?
        var signatureLineCount = 0
        var contactSignals = 0
        var signatureSupportSignals = 0
        var affiliationSupportSignals = 0
        var sawSignOffLine = false
        var sawSeparator = false

        for index in stride(from: lastNonEmpty, through: scanStart, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
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

            let isContinuationLine = signatureLineCount > 0 && isLikelySignatureContinuation(line)
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
                affiliationSupportSignals == 0 &&
                !sawSignOffLine &&
                hasContactListIntroBeforeSignature(startingAt: startLine, lines: lines) {
                return trimmed
            }
            let totalChars = trimmed.count
            if contactSignals == 0 && nonEmptyLineCount <= 4 && totalChars < 180 {
                return trimmed
            }
            if contactSignals == 1 && signatureLineCount <= 1 &&
                !hasSupportingSignatureContext(startingAt: startLine, lines: lines, lastNonEmpty: lastNonEmpty) {
                return trimmed
            }
            let adjustedStart = adjustToSeparator(startLine, lines: lines)
            return joinLines(lines, upTo: adjustedStart)
        }

        return trimmed
    }

    // MARK: - Line Evaluation

    private static func evaluateLine(_ line: String) -> LineEvaluation {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let isDelimiter = matchesRegex(delimiterLinePattern, in: trimmed)
        let isCidLine = lowercased.hasPrefix("[cid:")
        let hasHardFragment = hardIndicatorFragments.contains { lowercased.contains($0) }
        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed)
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
        let isHardIndicator = isDelimiter || isCidLine || hasHardFragment || hasContactPrefix

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
        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed)
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

    private static func hasSupportingSignatureContext(
        startingAt startLine: Int,
        lines: [String],
        lastNonEmpty: Int
    ) -> Bool {
        let lookbackStart = max(0, startLine - 4)
        for index in stride(from: startLine - 1, through: lookbackStart, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let lowercased = line.lowercased()
            let evaluation = evaluateLine(line)
            if isSignOffLine(lowercased) ||
                evaluation.hasContactInfo ||
                evaluation.isHardIndicator ||
                containsKeyword(lowercased, in: titleKeywords) ||
                containsKeyword(lowercased, in: organizationKeywords) ||
                containsAddressKeyword(lowercased) {
                return true
            }
        }

        var contactLineCount = 0
        for index in startLine...lastNonEmpty {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let evaluation = evaluateLine(line)
            if evaluation.hasContactInfo {
                contactLineCount += 1
                if contactLineCount >= 2 {
                    return true
                }
            }
        }

        return false
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

        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed)
        let hasEmail = matchesRegex(emailPattern, in: trimmed)
        let hasUrl = matchesRegex(urlPattern, in: trimmed)
        let hasPhoneCandidate = matchesRegex(phonePattern, in: trimmed)
        let hasStandalonePhone = hasPhoneCandidate && looksLikeStandalonePhoneLine(trimmed, lowercased: lowercased)
        if hasContactPrefix || hasEmail || hasUrl || hasStandalonePhone {
            return true
        }

        // Address-style continuation line (e.g., "New York, NY 10013")
        if trimmed.count <= 72,
           trimmed.contains(","),
           trimmed.range(of: "\\d", options: .regularExpression) != nil {
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
