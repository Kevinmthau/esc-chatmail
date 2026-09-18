import Foundation

/// Shared, pre-compiled pattern definitions for the text-processing pipeline.
///
/// These were previously duplicated verbatim across
/// `PlainTextSignatureRemover`, `EmailDOMQuoteRemover+Signatures`,
/// `PlainTextQuoteRemover`, `ChatBubbleTextProcessor`, `TextProcessing`, and
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

    /// A whole line that is only a host name, optionally labelled ("Web: acme.co.uk",
    /// "www.nordvik.no", "acmeadvisory.com"). Vendor signature generators print the
    /// bare company domain on its own row, which `webURL` misses without a scheme or
    /// `www.`. Every label needs two characters and the TLD comes from an explicit
    /// allowlist, so "e.g.", "M.Sc" and most lone filenames ("main.cc", "README.md",
    /// "script.py", "photos.heic") never read as a host. Some extensions are also
    /// country codes ("main.tf", "Logo.ai", "script.pl"), which is why callers let a
    /// bare host corroborate a contact block but never anchor one on its own. Whole-line
    /// only: a domain mentioned inside prose is not a contact row.
    static let bareHostLine: NSRegularExpression? = {
        let generic = "com|net|org|edu|gov|mil|int|info|biz|name|tel|travel|jobs|aero|coop|museum|asia|" +
            "io|co|ai|app|dev|tech|online|site|store|shop|blog|cloud|digital|agency|studio|design|media|group|" +
            "global|company|consulting|partners|law|legal|health|care|capital|finance|bank|fund|insurance|realty|" +
            "homes|properties|church|foundation|ngo|tours|club|team|works|solutions|services|systems|software|" +
            "network|email|live|tv|fm|me|xyz|top|world|today|news|expert|academy|school|university|institute|" +
            "clinic|dental|doctor|pharmacy|energy|solar|construction|builders|plumbing|roofing|photography|video|" +
            "film|music|art|gallery|events|wedding|boutique|fashion|beauty|fitness|restaurant|cafe|wine|" +
            "bar|hotel|rentals|apartments|house|land|farm|garden|vet|llc|ltd|limited"
        // ISO 3166 country codes minus the ones that double as source or document
        // extensions (cc, so, ml, pm, am, sc, sh, md, ps, rs, py).
        let country = "ac|ad|ae|af|ag|ai|al|ao|aq|ar|as|at|au|aw|ax|az|ba|bb|bd|be|bf|bg|bh|bi|bj|bm|bn|bo|br|bs|" +
            "bt|bw|by|bz|ca|cd|cf|cg|ch|ci|ck|cl|cm|cn|co|cr|cu|cv|cw|cx|cy|cz|de|dj|dk|dm|do|dz|ec|ee|eg|er|es|" +
            "et|eu|fi|fj|fk|fm|fo|fr|ga|gb|gd|ge|gf|gg|gh|gi|gl|gm|gn|gp|gq|gr|gs|gt|gu|gw|gy|hk|hm|hn|hr|ht|hu|" +
            "id|ie|il|im|in|io|iq|ir|is|it|je|jm|jo|jp|ke|kg|kh|ki|km|kn|kp|kr|kw|ky|kz|la|lb|lc|li|lk|lr|ls|lt|" +
            "lu|lv|ly|ma|mc|me|mg|mh|mk|mm|mn|mo|mp|mq|mr|ms|mt|mu|mv|mw|mx|my|mz|na|nc|ne|nf|ng|ni|nl|no|np|nr|" +
            "nu|nz|om|pa|pe|pf|pg|ph|pk|pl|pn|pr|pt|pw|qa|re|ro|ru|rw|sa|sb|sd|se|sg|si|sj|sk|sl|sm|sn|sr|ss|st|" +
            "su|sv|sx|sy|sz|tc|td|tf|tg|th|tj|tk|tl|tm|tn|to|tr|tt|tv|tw|tz|ua|ug|uk|us|uy|uz|va|vc|ve|vg|vi|vn|" +
            "vu|wf|ws|ye|yt|za|zm|zw"
        return try? NSRegularExpression(
            pattern: "^(?:(?:web(?:site)?|w|url|site|www)\\s*[:.]?\\s+)?(?:[a-z0-9][a-z0-9-]{0,61}[a-z0-9]\\.)+(?:" +
                generic + "|" + country + ")/?$",
            options: [.caseInsensitive]
        )
    }()
}

enum SignaturePatterns {
    /// Shared vocabulary; HTML callers adapt whitespace and tag boundaries themselves.
    static let signOffPhrases: Set<String> = [
        "all the best", "best", "best regards", "best wishes", "cheers", "kind regards",
        "many thanks", "regards", "sincerely", "take care", "thank you", "thanks",
        "warm regards", "warmly", "yours truly",
        // Gratitude and regards closings only. Sentence-shaped well-wishes ("have a
        // nice weekend", "talk soon") stay out: `TextProcessing.formatSignOffLineBreaks`
        // consumes this list and would break them off mid-paragraph.
        "thanks so much", "thank you so much", "thanks again", "thank you again",
        "thanks a lot", "thanks very much", "thank you very much", "thanks in advance",
        "thank you in advance", "much appreciated", "with thanks", "with gratitude",
        "gratefully", "kindest regards", "warmest regards", "with kind regards",
        "with best regards", "with warm regards", "very best", "very best regards",
        "all my best", "my best", "yours sincerely", "sincerely yours", "yours faithfully",
        "respectfully", "respectfully yours", "rgds", "thx", "thanks and regards",
        "thanks & regards", "warm wishes"
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
/// detection and the residual-HTML-text cleanup in
/// `ChatBubbleTextProcessor+HTMLTextExtraction`.
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

    /// A body line that introduces the block after it ("Please send the check to:",
    /// "Reviewer contact:") owns that block. Every signature pass consults this one
    /// veto so a referral card, payee address or contact list is never trimmed as a
    /// signature. It is deliberately a false-negative-only rule: an intro line
    /// followed by a genuine signature keeps the signature visible.
    static func isAuthoredLeadInLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasSuffix(":") || trimmed.hasSuffix("\u{FF1A}")
    }
}
