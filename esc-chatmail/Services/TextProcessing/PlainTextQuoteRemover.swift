import Foundation

/// Removes quoted text and signatures from plain text email content
/// Handles reply quotes, forwarded messages, and common signature patterns
enum PlainTextQuoteRemover {

    // MARK: - Quote Indicator Patterns

    /// Regex patterns that indicate quoted content
    private static let quoteIndicatorPatterns = [
        // Time-based quotes
        "On .+ wrote:",
        "On .+, .+ wrote:",
        "> On .+, at .+, .+ wrote:",

        // Header-based quotes - Outlook style (uses "Sent:")
        "From: .+\nSent: .+\nTo: .+\nSubject: .+",
        // Header-based quotes - Apple Mail style (uses "Date:")
        "From: .+\nDate: .+\nTo: .+\nSubject: .+",
        "From: .+\nDate: .+\nTo: .+\nCc: .+\nSubject: .+",
        "-----Original Message-----",
        "________________________________",

        // Forward indicators
        "Begin forwarded message:",
        "---------- Forwarded message ---------",
        "------ Original Message ------",
    ]

    // MARK: - Signature Patterns

    /// String patterns that indicate the start of a signature or boilerplate
    private static let signaturePatterns = [
        // Standard signature delimiters
        "\n--\n",
        "\n-- \n",
        "\n---\n",
        "\n___\n",
        "\n- ",           // Single dash with space (common in casual emails)
        "\n-\n",          // Single dash on its own line
        "\n—",            // Em-dash signature delimiter
        "\n– ",           // En-dash with space

        // Common sign-offs (must be on their own line to avoid false positives)
        "\nThanks,",
        "\nThank you,",
        "\nThanks!",
        "\nRegards,",
        "\nBest regards,",
        "\nKind regards,",
        "\nWarm regards,",
        "\nBest,",
        "\nCheers,",
        "\nAll the best,",
        "\nTake care,",
        "\nSincerely,",
        "\nYours truly,",
        "\nRespectfully,",
        "\nWith thanks,",
        "\nMany thanks,",
        "\nWith best wishes,",
        "\nBest wishes,",

        // Mobile signatures
        "\nSent from my iPhone",
        "\nSent from my iPad",
        "\nSent from my Android",
        "\nSent from Mail for Windows",
        "\nSent from Outlook",
        "\nGet Outlook for",
        "\nSent from Yahoo Mail",
        "\nSent via ",
        "\nSent using ",
        "\nSent from Samsung",
        "\nSent from my Galaxy",
        "\nSent from my Pixel",
        "\nSent from my mobile",
        "\nSent from my phone",
        "\nSent from BlueMail",
        "\nSent from Spark",
        "\nSent from ProtonMail",
        "\nSent from Gmail",
        "\nSent from TypeApp",
        "\nGet BlueMail for",
        "\nDownload Outlook",

        // Unsubscribe and preference links
        "\nUnsubscribe",
        "\nUpdate your email preferences",
        "\nManage your subscription",
        "\nClick here to unsubscribe",
        "\nTo stop receiving",
        "\nOpt out of future",
        "\nView this email in your browser",
        "\nHaving trouble viewing this email",
        "\nIf you wish to unsubscribe",
        "\nYou are receiving this",
        "\nYou received this email because",

        // Legal disclaimers
        "\nThis email and any attachments",
        "\nThis message is intended",
        "\nThis communication is confidential",
        "\nThis message contains confidential",
        "\nThis e-mail is confidential",
        "\nThe information in this email",
        "\nIf you are not the intended recipient",
        "\nIf you have received this email in error",
        "\nConfidentiality Notice:",
        "\nDISCLAIMER:",
        "\nLegal Disclaimer:",
        "\nIMPORTANT:",
        "\nPlease consider the environment",
        "\nThink before you print",

        // Social media and footer links
        "\nFollow us on",
        "\nConnect with us",
        "\nJoin us on",
        "\nFind us on",
        "\nVisit our website",
        "\nPrivacy Policy",
        "\nTerms of Service",
        "\nCopyright ©",
        "\n© 20",  // Catches "© 2024" etc

        // Professional footer patterns (URLs often start signature blocks)
        "\nwww.",
        "\nhttp://",
        "\nhttps://",

        // Marketing boilerplate
        "\nForward to a friend",
        "\nShare this email",
        "\nReply STOP to unsubscribe",
    ]

    // MARK: - Public API

    /// Removes quoted text from plain text email content
    /// - Parameter text: The plain text content to clean
    /// - Returns: Text with quotes and signatures removed, or nil if input was nil
    static func removeQuotes(from text: String?) -> String? {
        guard let text = text else { return nil }

        var cleanText = text
        var earliestQuoteIndex = cleanText.count

        // Find earliest regex quote indicator
        earliestQuoteIndex = min(
            earliestQuoteIndex,
            findEarliestPatternMatch(in: cleanText)
        )

        // Check for consecutive ">" quote lines
        earliestQuoteIndex = min(
            earliestQuoteIndex,
            findConsecutiveQuoteLines(in: cleanText)
        )

        // Truncate at quote indicator
        if earliestQuoteIndex < cleanText.count {
            let endIndex = cleanText.index(cleanText.startIndex, offsetBy: earliestQuoteIndex)
            cleanText = String(cleanText[..<endIndex])
        }

        // Remove signatures
        cleanText = removeSignature(from: cleanText)

        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes email signatures and boilerplate from text
    /// - Parameter text: The text to clean
    /// - Returns: Text with signature removed
    static func removeSignature(from text: String) -> String {
        var cleanText = text
        var earliestCutIndex = cleanText.count

        // Find the earliest occurrence of any signature pattern
        for pattern in signaturePatterns {
            if let range = cleanText.range(of: pattern, options: [.caseInsensitive]) {
                let index = cleanText.distance(from: cleanText.startIndex, to: range.lowerBound)
                earliestCutIndex = min(earliestCutIndex, index)
            }
        }

        // Cut at the earliest signature marker
        if earliestCutIndex < cleanText.count {
            let endIndex = cleanText.index(cleanText.startIndex, offsetBy: earliestCutIndex)
            cleanText = String(cleanText[..<endIndex])
        }

        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    /// Finds the earliest match of any quote indicator pattern
    private static func findEarliestPatternMatch(in text: String) -> Int {
        var earliestIndex = text.count

        for pattern in quoteIndicatorPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let matchRange = Range(match.range, in: text) {
                let index = text.distance(from: text.startIndex, to: matchRange.lowerBound)
                earliestIndex = min(earliestIndex, index)
            }
        }

        return earliestIndex
    }

    /// Finds the start of consecutive ">" quoted lines (2+ lines)
    private static func findConsecutiveQuoteLines(in text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        var consecutiveQuoteLines = 0

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix(">") {
                consecutiveQuoteLines += 1
                // If we find 2+ consecutive quote lines, consider it quoted text
                if consecutiveQuoteLines >= 2 {
                    let precedingLines = lines[0..<max(0, index - consecutiveQuoteLines + 1)]
                    let precedingText = precedingLines.joined(separator: "\n")
                    return precedingText.count
                }
            } else {
                consecutiveQuoteLines = 0
            }
        }

        return text.count
    }
}
