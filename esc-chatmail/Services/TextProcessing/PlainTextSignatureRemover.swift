import Foundation

/// Detects and removes signature blocks from plain text email content.
/// Designed to be conservative for short messages while reliably stripping
/// trailing contact blocks, mobile footers, and legal boilerplate.
enum PlainTextSignatureRemover {

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
        "this email and any attachments",
        "this message is intended",
        "this communication is confidential",
        "this message contains confidential",
        "this e-mail is confidential",
        "the information in this email",
        "if you are not the intended recipient",
        "if you have received this email in error",
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
        "kind regards",
        "warm regards",
        "take care",
        "all the best"
    ]

    private static let delimiterLinePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(--|--\\s|---|___|—|–|-)$|^[-_]{2,}$", options: [.caseInsensitive])
    }()

    private static let contactPrefixPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(m|c|o|f|d|t|p|tel|phone|mobile|office|direct|fax)\\s*[:.-]\\s*\\S+", options: [.caseInsensitive])
    }()

    private static let emailPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])
    }()

    private static let urlPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\bhttps?://\\S+|\\bwww\\.[^\\s]+", options: [.caseInsensitive])
    }()

    private static let phonePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b\\+?\\d[\\d\\s().-]{6,}\\b", options: [])
    }()

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

    private static let organizationKeywords: [String] = [
        " inc", " inc.", " llc", " ltd", " corp", " corp.", " corporation",
        " company", " co.", " partners", " group"
    ]

    // MARK: - Public API

    static func removeSignature(from text: String) -> String {
        let normalized = normalizeLineEndings(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return trimmed }

        var lastNonEmpty = lines.count - 1
        while lastNonEmpty >= 0 && lines[lastNonEmpty].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastNonEmpty -= 1
        }
        guard lastNonEmpty >= 0 else { return "" }

        let scanStart = max(0, lastNonEmpty - 18)
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
            let startLine = findSignatureStartLine(before: hardIndicatorIndex, lines: lines)
            return joinLines(lines, upTo: startLine)
        }

        // Pass 2: Heuristic trailing block detection (contact info or titles).
        var signatureStartLine: Int?
        var signatureLineCount = 0
        var contactSignals = 0
        var sawSeparator = false

        for index in stride(from: lastNonEmpty, through: scanStart, by: -1) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
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

            if evaluation.isLikelySignatureLine {
                signatureLineCount += 1
                if signatureStartLine == nil {
                    signatureStartLine = index
                }
            } else if signatureLineCount > 0 {
                break
            }
        }

        if let startLine = signatureStartLine {
            let totalChars = trimmed.count
            if contactSignals == 0 && nonEmptyLineCount <= 4 && totalChars < 180 {
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

        let hasEmail = matchesRegex(emailPattern, in: trimmed)
        let hasUrl = matchesRegex(urlPattern, in: trimmed)
        let hasPhone = matchesRegex(phonePattern, in: trimmed)

        let hasContactInfo = hasContactPrefix || hasEmail || hasUrl || hasPhone

        // URLs and phone numbers on trailing lines are usually signature/footer markers.
        let isHardIndicator = isDelimiter || isCidLine || hasHardFragment || hasContactPrefix || hasUrl || hasPhone

        var score = 0
        if isSignOffLine(lowercased) { score += 1 }
        if hasContactInfo { score += 3 }
        if containsKeyword(lowercased, in: titleKeywords) { score += 1 }
        if containsKeyword(lowercased, in: addressKeywords) { score += 1 }
        if trimmed.count <= 72 { score += 1 }
        if trimmed.contains("|") { score += 1 }

        if looksLikeSentence(trimmed) { score -= 1 }
        if TextProcessing.isListItem(trimmed) { score -= 2 }

        let isLikelySignatureLine = score >= 2

        return LineEvaluation(
            isHardIndicator: isHardIndicator,
            isLikelySignatureLine: isLikelySignatureLine,
            hasContactInfo: hasContactInfo
        )
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

    private static func looksLikeSentence(_ line: String) -> Bool {
        guard line.count > 40 else { return false }
        return line.hasSuffix(".") || line.hasSuffix("!") || line.hasSuffix("?")
    }

    private static func containsKeyword(_ text: String, in keywords: [String]) -> Bool {
        return keywords.contains { text.contains($0) }
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
                    signatureStartLine = index
                    break
                }
                continue
            }

            let evaluation = evaluateLine(line)
            if evaluation.isHardIndicator || looksLikeSignatureLine(line) {
                foundShortLines = true
            } else {
                break
            }
        }

        return signatureStartLine ?? indicatorIndex
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
        let hasContactPrefix = matchesRegex(contactPrefixPattern, in: trimmed)
        let hasEmail = matchesRegex(emailPattern, in: trimmed)
        let hasUrl = matchesRegex(urlPattern, in: trimmed)
        let hasPhone = matchesRegex(phonePattern, in: trimmed)
        let lowercased = trimmed.lowercased()

        if hasContactPrefix || hasEmail || hasUrl || hasPhone {
            return true
        }

        if containsKeyword(lowercased, in: organizationKeywords) {
            return true
        }

        return shortEnough && (noSentenceEnding || trimmed.hasSuffix(","))
    }

    // MARK: - Utilities

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

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
}
