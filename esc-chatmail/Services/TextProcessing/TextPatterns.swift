import Foundation

/// Shared, pre-compiled pattern definitions for the text-processing pipeline.
///
/// These were previously duplicated verbatim across
/// `PlainTextSignatureRemover`, `EmailDOMQuoteRemover+Signatures`,
/// `PlainTextQuoteRemover`, `ProcessedTextCache`, `TextProcessing`, and
/// `RawEmailSourceSanitizer`. Callers keep their own matching logic and alias
/// these definitions, so each pattern has exactly one home.

enum EmailPatterns {
    /// Matches an email address anywhere in a line.
    static let address: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])
    }()
}

enum URLPatterns {
    /// Matches http(s) URLs and bare `www.` hosts anywhere in a line.
    static let webURL: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\bhttps?://\\S+|\\bwww\\.[^\\s]+", options: [.caseInsensitive])
    }()
}

enum SignaturePatterns {
    /// Shared vocabulary; HTML callers adapt whitespace and tag boundaries themselves.
    static let signOffPhrases: Set<String> = [
        "all the best", "best", "best regards", "best wishes", "cheers", "kind regards",
        "many thanks", "regards", "sincerely", "take care", "thank you", "thanks",
        "warm regards", "warmly", "yours truly"
    ]

    /// Paragraph-start legal boilerplate, deliberately excluding general body words.
    static let legalFooterOpeners = [
        #"^\s*confidentiality notice\s*:"#,
        #"^\s*this e-?mail (?:and any attachments|is confidential|may contain)\b"#,
        #"^\s*disclaimer\s*:"#
    ]

    /// Explicit phone-label phrases avoid treating fields such as "Service period" as contact details.
    /// Callers also apply the normal phone-candidate/date and suffix validation.
    static let descriptivePhoneLine: NSRegularExpression? = {
        let label = #"(?:after[ -]hours|(?:emergency|after[ -]hours|toll[ -]free|customer service|service|dispatch)[ -]+(?:phone|line|number)(?:[ -]+after[ -]hours)?)\s*:"#
        let number = #"(?=(?:[\s().+-]*\d){7})\+?\(?\d{1,4}\)?(?:[\s.-]+\(?\d{1,4}\)?){1,4}"#
        let suffix = #"(?:\s*(?:x|ext\.?|extension|#)\s*:?\s*\d+|\s*\((?:mobile|cell|office|work|home|direct|desk|main|fax)\))?"#
        return try? NSRegularExpression(pattern: "^" + label + #"\s*"# + number + suffix + "$", options: [.caseInsensitive])
    }()

    static let nameContactWord: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(?:fax|mobile|office|cell|phone)\b"#, options: [.caseInsensitive])
    }()

    static let supportKeyword: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\b(?:director|manager|vp|vice president|president|founder|ceo|cfo|cto|coo|realtor|broker|associate|sales|agent|partner|principal|owner|specialist)\b|\s(?:inc|llc|ltd|corp|corporation|company|partners|group|llp|lp)\b|\sco\."#,
            options: [.caseInsensitive]
        )
    }()

    /// Added roles require a complete title phrase, not a keyword anywhere in a sentence.
    static let additionalSupportTitle: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:(?:(?:chief|executive|senior|junior|lead|staff|loan|financial|investment|legal|technical|software|systems|project|account|marketing|operations|general|assistant)\s+){0,2}(?:officer|chief|advisor|consultant|engineer|attorney|counsel|analyst|coordinator)|[a-z][a-z'’.-]+\s+(?:insurance|travel|real estate|staffing|marketing|advertising|creative)\s+agency)$"#,
            options: [.caseInsensitive]
        )
    }()

    static let supportProse: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\b(?:please|not|never|no|without|must|shall|should|will|would|could|cannot|is|are|was|were|be|been|being|pending|awaiting|required|approval|pay|payment|fees|due|my|our|your|their)\b|^(?:i|we|you|he|she|it|they|do|check|ask|ensure|remember|confirm|send|wait|get|need|call|contact|use)\b"#,
            options: [.caseInsensitive]
        )
    }()

    /// Phone-number candidate: 7+ digits with common separators.
    static let phone: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b\\+?\\d[\\d\\s().-]{6,}\\b", options: [])
    }()

    /// Street/suite/floor keywords, matched on word boundaries to avoid
    /// substring false positives like "ave" inside "have".
    static let addressKeyword: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?i)\b(?:street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|suite|ste|floor|fl)\b\.?"#,
            options: []
        )
    }()

    /// Standalone one-letter contact labels ("m:", "t.", "p").
    static let standaloneContactLabel: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(m|c|o|f|d|t|p)[:.]?$", options: [.caseInsensitive])
    }()

    /// Signature delimiter lines ("--", "___", em/en dash variants).
    static let delimiterLine: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(--|--\\s|---|___|—|–|-)$|^[-_]{2,}$", options: [.caseInsensitive])
    }()
}

/// Localized quoted-reply header prefixes (lowercased), grouped by header
/// role. Shared by the plain-text quote remover's structural header-block
/// detection and the residual-HTML-text cleanup in ProcessedTextCache.
enum QuoteHeaderPatterns {
    static let fromPrefixes: [String] = [
        "from:", "von:", "de:", "de :", "da:", "van:"
    ]

    static let toPrefixes: [String] = [
        "to:", "an:", "à:", "à :", "para:", "aan:"
    ]

    static let sentOrDatePrefixes: [String] = [
        "sent:", "date:", "gesendet:", "datum:", "envoyé:", "envoyé :", "enviado:", "inviato:", "verzonden:"
    ]

    static let subjectPrefixes: [String] = [
        "subject:", "betreff:", "objet:", "objet :", "asunto:", "oggetto:", "assunto:", "onderwerp:"
    ]
}

enum MIMEPatterns {
    /// Per-part MIME header prefixes (lowercased) stripped from displayed text.
    static let headerPrefixes: [String] = [
        "content-type:",
        "content-transfer-encoding:",
        "content-disposition:",
        "content-id:",
        "content-description:",
        "x-attachment-id:",
        "mime-version:"
    ]

    /// Extracts boundary tokens from Content-Type headers.
    static let boundary: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"boundary\s*=\s*(?:"([^"]+)"|([^\s;]+))"#,
            options: [.caseInsensitive]
        )
    }()
}

/// Keep a personal sign-off/name pair while excluding contact details and role/company lines.
enum SignatureSignOffPolicy {
    static func looksLikeNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40,
              trimmed.rangeOfCharacter(from: .letters) != nil,
              trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let lowercased = trimmed.lowercased()
        guard !["@", "http", "www.", "|", "tel:"].contains(where: lowercased.contains) else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard SignaturePatterns.nameContactWord?.firstMatch(in: trimmed, range: range) == nil else { return false }
        return (1...4).contains(trimmed.split(whereSeparator: \.isWhitespace).count)
    }

    static func isStrongSupportLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count < 8 else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        // Capitalization does not make an instruction a title (e.g. "DO NOT PAY THE CONSULTANT").
        guard SignaturePatterns.supportProse?.firstMatch(in: trimmed, range: range) == nil else { return false }
        if let last = trimmed.last, ".?!".contains(last),
           trimmed.range(of: #"\b(?:inc|co|corp)\.$"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return false
        }
        if SignaturePatterns.additionalSupportTitle?.firstMatch(in: trimmed, range: range)?.range == range {
            return true
        }
        guard SignaturePatterns.supportKeyword?.firstMatch(
            in: trimmed, range: range
        ) != nil else { return false }

        // A role mentioned in an instruction is not a removable title. Unknown
        // lowercase phrases stay visible; standalone roles still work in any case.
        if words.count == 1 { return true }
        let joiners: Set<String> = ["and", "of", "at", "for", "the", "in", "de", "van", "von", "&", "/", "|", "-", "–"]
        return words.allSatisfy { word in
            if joiners.contains(word.lowercased()) { return true }
            return word.first(where: \.isLetter)?.isUppercase == true
        }
    }

    static func shouldPreserveNameLine(_ line: String) -> Bool {
        looksLikeNameLine(line) && !isStrongSupportLine(line)
    }
}
