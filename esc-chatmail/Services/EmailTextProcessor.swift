import Foundation
import SwiftUI

class EmailTextProcessor {
    
    // MARK: - HTML Processing
    
    /// Removes quoted text from HTML email content
    static func removeQuotedFromHTML(_ html: String?) -> String? {
        guard let html = html else { return nil }

        var cleanedHTML = html

        // Remove common HTML quote blocks
        let htmlQuotePatterns = [
            // Gmail quote blocks
            "<div class=\"gmail_quote\">.*?</div>",
            "<blockquote[^>]*>.*?</blockquote>",

            // Outlook/Office 365
            "<div class=\"OutlookMessageHeader\">.*?</div>",
            "<div style=\"border:none;border-top:solid #E1E1E1[^>]*>.*?</div>",

            // Apple Mail
            "<br><div><br><blockquote type=\"cite\">.*?</blockquote></div>",

            // Generic quoted sections
            "<div style=\"[^\"]*border-left:[^\"]*\">.*?</div>",
            "<!-- originalMessage -->.*?<!-- /originalMessage -->",
            "<div class=\"moz-cite-prefix\">.*?</div>",

            // Email footers and boilerplate
            "<div[^>]*class=\"[^\"]*footer[^\"]*\"[^>]*>.*?</div>",
            "<table[^>]*class=\"[^\"]*footer[^\"]*\"[^>]*>.*?</table>",
            "<div[^>]*id=\"[^\"]*footer[^\"]*\"[^>]*>.*?</div>",

            // Social media and icon sections
            "<table[^>]*class=\"[^\"]*social[^\"]*\"[^>]*>.*?</table>",
            "<div[^>]*class=\"[^\"]*social[^\"]*\"[^>]*>.*?</div>",

            // Unsubscribe sections
            "<div[^>]*class=\"[^\"]*unsubscribe[^\"]*\"[^>]*>.*?</div>",
            "<p[^>]*class=\"[^\"]*unsubscribe[^\"]*\"[^>]*>.*?</p>"
        ]

        // Remove quote patterns
        for pattern in htmlQuotePatterns {
            if let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) {
                let range = NSRange(location: 0, length: cleanedHTML.utf16.count)
                cleanedHTML = regex.stringByReplacingMatches(
                    in: cleanedHTML,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }
        }

        // Remove "On ... wrote:" patterns and everything after
        let writePatterns = [
            "On .+? wrote:",
            "From:</strong>.*?Subject:</strong>",
            "-----Original Message-----"
        ]

        for pattern in writePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let range = NSRange(location: 0, length: cleanedHTML.utf16.count)
                if let match = regex.firstMatch(in: cleanedHTML, options: [], range: range) {
                    let matchRange = Range(match.range, in: cleanedHTML)
                    if let matchRange = matchRange {
                        cleanedHTML = String(cleanedHTML[..<matchRange.lowerBound])
                    }
                }
            }
        }

        return cleanedHTML
    }
    
    /// Extracts plain text from HTML, removing tags but preserving structure
    static func extractPlainFromHTML(_ html: String) -> String {
        // Convert HTML to AttributedString to extract plain text
        guard let data = html.data(using: .utf8) else { return html }
        
        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            // Fallback: basic HTML tag removal
            return html
                .replacingOccurrences(of: "<br>", with: "\n")
                .replacingOccurrences(of: "<br/>", with: "\n")
                .replacingOccurrences(of: "<br />", with: "\n")
                .replacingOccurrences(of: "</p>", with: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    // MARK: - Plain Text Processing
    
    /// Removes quoted text from plain text email content
    static func removeQuotedFromPlainText(_ text: String?) -> String? {
        guard let text = text else { return nil }
        
        var cleanText = text
        
        // Find the earliest quote indicator
        let quoteIndicators = [
            // Time-based quotes
            "On .+ wrote:",
            "On .+, .+ wrote:",
            "> On .+, at .+, .+ wrote:",
            
            // Header-based quotes
            "From: .+\nSent: .+\nTo: .+\nSubject: .+",
            "-----Original Message-----",
            "________________________________",
            
            // Forward indicators
            "Begin forwarded message:",
            "---------- Forwarded message ---------",
            "------ Original Message ------"
        ]
        
        var earliestQuoteIndex = cleanText.count
        
        // Check regex patterns
        for pattern in quoteIndicators {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: cleanText.utf16.count)
                if let match = regex.firstMatch(in: cleanText, options: [], range: range) {
                    let matchRange = Range(match.range, in: cleanText)
                    if let matchRange = matchRange {
                        let index = cleanText.distance(from: cleanText.startIndex, to: matchRange.lowerBound)
                        earliestQuoteIndex = min(earliestQuoteIndex, index)
                    }
                }
            }
        }
        
        // Check for lines starting with ">"
        let lines = cleanText.components(separatedBy: .newlines)
        var consecutiveQuoteLines = 0
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix(">") {
                consecutiveQuoteLines += 1
                // If we find 2+ consecutive quote lines, consider it quoted text
                if consecutiveQuoteLines >= 2 {
                    let precedingLines = lines[0..<max(0, index - consecutiveQuoteLines + 1)]
                    let precedingText = precedingLines.joined(separator: "\n")
                    earliestQuoteIndex = min(earliestQuoteIndex, precedingText.count)
                    break
                }
            } else {
                consecutiveQuoteLines = 0
            }
        }
        
        // Truncate at quote indicator
        if earliestQuoteIndex < cleanText.count {
            let endIndex = cleanText.index(cleanText.startIndex, offsetBy: earliestQuoteIndex)
            cleanText = String(cleanText[..<endIndex])
        }
        
        // Remove signatures
        cleanText = removeEmailSignature(from: cleanText)
        
        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Removes common email signatures, disclaimers, and boilerplate
    private static func removeEmailSignature(from text: String) -> String {
        let signaturePatterns = [
            // Standard signature delimiters
            "\n--\n",
            "\n-- \n",
            "\n---\n",
            "\n___\n",

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
            "\n© 20", // Catches "© 2024" etc

            // Marketing boilerplate
            "\nForward to a friend",
            "\nShare this email",
            "\nReply STOP to unsubscribe"
        ]

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
    
    // MARK: - Snippet Creation

    /// Creates a clean snippet from email content
    /// Default maxLength is set to 5000 to show ALL newly written text without truncation
    static func createCleanSnippet(from text: String?, maxLength: Int = 5000, firstSentenceOnly: Bool = false) -> String {
        guard let text = text, !text.isEmpty else { return "" }

        // Clean the text
        let cleanedText = removeQuotedFromPlainText(text) ?? text

        // Remove excessive whitespace and newlines
        let condensed = cleanedText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // If only first sentence is requested, extract it
        if firstSentenceOnly {
            return extractFirstSentence(from: condensed)
        }

        // Truncate if needed
        if condensed.count > maxLength {
            let endIndex = condensed.index(condensed.startIndex, offsetBy: maxLength)
            return String(condensed[..<endIndex]) + "..."
        }

        return condensed
    }

    /// Extracts the first sentence from text
    private static func extractFirstSentence(from text: String) -> String {
        // Look for sentence-ending punctuation followed by space or end of string
        let sentenceEndPattern = "[.!?](?:\\s|$)"

        if let regex = try? NSRegularExpression(pattern: sentenceEndPattern, options: []),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range, in: text) {
            let endIndex = range.upperBound
            return String(text[..<endIndex]).trimmingCharacters(in: .whitespaces)
        }

        // If no sentence ending found, return the whole text (up to a reasonable limit)
        let limit = min(text.count, 200)
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        let snippet = String(text[..<endIndex])
        return limit < text.count ? snippet + "..." : snippet
    }
    
    /// Creates an attributed string from HTML for rich display
    static func createAttributedString(fromHTML html: String?) -> AttributedString? {
        guard let html = html else { return nil }
        
        // Clean the HTML first
        guard let cleanedHTML = removeQuotedFromHTML(html) else { return nil }
        
        // Convert to AttributedString
        guard let data = cleanedHTML.data(using: .utf8) else { return nil }
        
        do {
            let nsAttributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            return AttributedString(nsAttributed)
        } catch {
            print("Failed to create attributed string from HTML: \(error)")
            return nil
        }
    }
}