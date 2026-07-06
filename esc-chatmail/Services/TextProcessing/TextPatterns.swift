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
