import Foundation

enum TextProcessing {
    /// Pre-compiled regex for list item detection
    /// Matches: 1. 10. 100. a) A. - * • · (a) (1)
    private static let listItemPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^(\\d{1,3}[.)]|[a-zA-Z][.)]|[-*•·]|\\([a-zA-Z0-9]{1,3}\\))\\s",
            options: []
        )
    }()

    /// Checks if a line starts with a list item marker
    static func isListItem(_ line: String) -> Bool {
        guard let regex = listItemPattern else {
            // Fallback to simple check
            return line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") || line.hasPrefix("·")
        }
        let range = NSRange(location: 0, length: min(line.utf16.count, 10)) // Only check first 10 chars
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }
    static func extractPlainText(from html: String) -> String {
        var text = html

        // Avoid leaking <head> metadata (title tags, MSO conditionals) into bubble text.
        // Also strip HTML comments entirely; conditional comments often contain Outlook-only XML
        // that can show up as garbage like "96" in extracted plain text.
        text = text.replacingOccurrences(
            of: "<head\\b[^>]*>[\\s\\S]*?</head>",
            with: "",
            options: [.regularExpression, .caseInsensitive],
            range: nil
        )
        text = text.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: [.regularExpression, .caseInsensitive],
            range: nil
        )

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert consecutive <br> tags to paragraph breaks, single <br> to space (soft wrap)
        // First: <br><br> or <br>\s*<br> → paragraph break
        text = text.replacingOccurrences(of: "<br[^>]*>\\s*<br[^>]*>", with: "\n\n", options: .regularExpression, range: nil)
        // Then: remaining single <br> → newline (let unwrapEmailLineBreaks decide whether to join)
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)

        // Paragraphs and headings get double newlines (actual content breaks)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression, range: nil)

        // Div closures create single newlines - let unwrapEmailLineBreaks decide whether to join
        // Gmail mobile wraps each line in <div>, so using \n allows smart join logic to work
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive, range: nil)

        // List items should each appear on their own line
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive, range: nil)

        // Tables: preserve row boundaries and add spacing between cells so text doesn't run together.
        // This is important for quote removal: Outlook/Apple "From/Sent/To/Subject" quote headers are often rendered in tables.
        text = text.replacingOccurrences(
            of: "</t[dh]>",
            with: " ",
            options: [.regularExpression, .caseInsensitive],
            range: nil
        )
        text = text.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive, range: nil)
        text = text.replacingOccurrences(of: "</table>", with: "\n\n", options: .caseInsensitive, range: nil)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        // Remove truncated opening tags (e.g., snippet cut in middle of `<div style="...`).
        text = text.replacingOccurrences(of: "<[a-zA-Z][^>\\n]*(?=\\n|$)", with: "", options: .regularExpression, range: nil)

        // Decode HTML entities (non-breaking space variants)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&#160;", with: " ")
        text = text.replacingOccurrences(of: "&#xA0;", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&#34;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")

        // Zero-width characters (strip entirely - they're invisible formatting)
        text = text.replacingOccurrences(of: "&zwnj;", with: "")
        text = text.replacingOccurrences(of: "&zwj;", with: "")
        text = text.replacingOccurrences(of: "&#8204;", with: "")
        text = text.replacingOccurrences(of: "&#8205;", with: "")
        text = text.replacingOccurrences(of: "&#x200C;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#x200D;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "\u{200C}", with: "")
        text = text.replacingOccurrences(of: "\u{200D}", with: "")
        text = text.replacingOccurrences(of: "\u{200B}", with: "") // zero-width space

        // Smart quotes and other typographic entities
        text = text.replacingOccurrences(of: "&ldquo;", with: "\"")
        text = text.replacingOccurrences(of: "&rdquo;", with: "\"")
        text = text.replacingOccurrences(of: "&lsquo;", with: "'")
        text = text.replacingOccurrences(of: "&rsquo;", with: "'")
        text = text.replacingOccurrences(of: "&#8220;", with: "\"")
        text = text.replacingOccurrences(of: "&#8221;", with: "\"")
        text = text.replacingOccurrences(of: "&#8216;", with: "'")
        text = text.replacingOccurrences(of: "&#8217;", with: "'")
        text = text.replacingOccurrences(of: "&ndash;", with: "–")
        text = text.replacingOccurrences(of: "&mdash;", with: "—")
        text = text.replacingOccurrences(of: "&#8211;", with: "–")
        text = text.replacingOccurrences(of: "&#8212;", with: "—")
        text = text.replacingOccurrences(of: "&hellip;", with: "…")
        text = text.replacingOccurrences(of: "&#8230;", with: "…")

        // Clean up whitespace
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression, range: nil)
        // Collapse whitespace-only lines to single newline
        text = text.replacingOccurrences(of: "\\n[ \\t]*\\n", with: "\n\n", options: .regularExpression, range: nil)
        // Collapse any sequence of newlines (with optional whitespace) to max 2 newlines
        text = text.replacingOccurrences(of: "(\\s*\\n\\s*){2,}", with: "\n\n", options: .regularExpression, range: nil)

        // Trim whitespace from each line to clean up artifacts like " \n" from decoded &nbsp;
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    static func stripQuotedText(from text: String) -> String {
        // Delegate to PlainTextQuoteRemover for unified quote and signature removal
        PlainTextQuoteRemover.removeQuotes(from: text) ?? text
    }

    static func stripSignatures(from text: String) -> String {
        PlainTextSignatureRemover.removeSignature(from: text)
    }

    /// Common sign-off words that should have a line break before them
    private static let signOffWords = ["regards", "thanks", "thank you", "best", "cheers", "sincerely", "yours truly", "best wishes", "kind regards", "warm regards", "take care", "all the best"]

    /// Adds line breaks before sign-offs when they appear inline at the end of text
    /// Handles cases like "...for your help. Regards, Kevin" → "...for your help.\n\nRegards,\n\nKevin"
    static func formatSignOffLineBreaks(in text: String) -> String {
        var result = text

        // Pattern: sentence ending (. ! ?) followed by space and a sign-off word
        for signOff in signOffWords {
            // Case-insensitive search for ". SignOff" pattern
            let patterns = [
                "([.!?])\\s+(\(signOff))([!.])?,?\\s*$",  // "help. Regards" or "help. Thanks!" at end - group 3 captures trailing punct
                "([.!?])\\s+(\(signOff)),\\s+([A-Z][a-z]+)\\s*$",  // "help. Regards, Kevin" at end
                "([.!?])\\s+(\(signOff)),\\s+([A-Z][a-z]+)\\s+([A-Z][a-z]+)\\s*$",  // "help. Regards, Kevin Thau" at end
            ]

            for (patternIndex, pattern) in patterns.enumerated() {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(location: 0, length: result.utf16.count)
                    if let match = regex.firstMatch(in: result, options: [], range: range) {
                        // Found a sign-off pattern - add line breaks
                        let punctuation = (result as NSString).substring(with: match.range(at: 1))
                        let signOffText = (result as NSString).substring(with: match.range(at: 2))

                        // First pattern captures trailing punctuation in group 3; others have name in group 3
                        let trailingPunct: String
                        if patternIndex == 0 && match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound {
                            trailingPunct = (result as NSString).substring(with: match.range(at: 3))
                        } else {
                            trailingPunct = ","
                        }

                        var replacement = "\(punctuation)\n\n\(signOffText)\(trailingPunct)"
                        // For patterns 2 and 3 (with names), group 3 is first name, group 4 is last name
                        if patternIndex > 0 && match.numberOfRanges > 3 {
                            let name = (result as NSString).substring(with: match.range(at: 3))
                            replacement += "\n\n\(name)"
                            if match.numberOfRanges > 4 {
                                let lastName = (result as NSString).substring(with: match.range(at: 4))
                                replacement += " \(lastName)"
                            }
                        }

                        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
                        break  // Only process one sign-off pattern
                    }
                }
            }
        }

        return result
    }

    /// Unwraps artificial email line breaks (72-80 char wrapping) while preserving paragraph breaks
    /// Emails often contain hard line breaks at fixed widths for legacy compatibility.
    /// This function joins lines that were artificially wrapped while keeping intentional paragraph breaks.
    static func unwrapEmailLineBreaks(from text: String) -> String {
        // Normalize line endings: CRLF → LF, CR → LF
        var normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Normalize all special whitespace to regular space
        // This handles NBSP (U+00A0), thin space, em space, etc. that would otherwise
        // cause the lowercase check to fail when determining if lines should be joined
        let specialWhitespace: [Character] = [
            "\u{00A0}",  // Non-breaking space
            "\u{2002}",  // En space
            "\u{2003}",  // Em space
            "\u{2009}",  // Thin space
            "\u{200A}",  // Hair space
            "\u{202F}",  // Narrow no-break space
            "\u{205F}",  // Medium mathematical space
            "\u{3000}",  // Ideographic space
        ]
        for char in specialWhitespace {
            normalizedText = normalizedText.replacingOccurrences(of: String(char), with: " ")
        }

        let lines = normalizedText.components(separatedBy: "\n")
        guard lines.count > 1 else { return normalizedText }

        var result: [String] = []
        var currentParagraph = ""
        var i = 0

        while i < lines.count {
            let trimmedLine = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            // Skip empty lines but check if we should join across them
            if trimmedLine.isEmpty {
                if currentParagraph.isEmpty {
                    continue
                }

                // Look ahead to find the next non-empty line
                var nextNonEmptyIndex = i
                while nextNonEmptyIndex < lines.count &&
                      lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                    nextNonEmptyIndex += 1
                }

                // Check if we should join across the blank line(s)
                if nextNonEmptyIndex < lines.count {
                    let nextLine = lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces)
                    let lastChar = currentParagraph.last
                    let firstChar = nextLine.first

                    let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                    // Join unless next line starts with uppercase (new sentence)
                    let startsWithUppercase = firstChar?.isUppercase ?? false

                    if !endsWithPunctuation && !startsWithUppercase {
                        // This is a soft wrap across blank lines - skip the blanks and continue joining
                        continue
                    }
                }

                // Real paragraph break - flush current paragraph
                result.append(currentParagraph)
                result.append("") // Add paragraph separator
                currentParagraph = ""
                continue
            }

            if currentParagraph.isEmpty {
                currentParagraph = trimmedLine
            } else {
                // Check if this looks like a continuation (soft wrap) or new paragraph
                let lastChar = currentParagraph.last
                let firstChar = trimmedLine.first

                let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                // Join unless next line starts with uppercase (new sentence)
                let startsWithUppercase = firstChar?.isUppercase ?? false

                // Don't join if current line ends with colon (often precedes lists)
                let endsWithColon = lastChar == ":"

                // Don't join if next line looks like a list item
                // Handles: 1. 10. 100. a) A. - * • · (a) (1)
                let isListItem = TextProcessing.isListItem(trimmedLine)

                if !endsWithPunctuation && !endsWithColon && !startsWithUppercase && !isListItem {
                    // Join with space (unwrap soft line break)
                    currentParagraph += " " + trimmedLine
                } else {
                    // New paragraph
                    result.append(currentParagraph)
                    currentParagraph = trimmedLine
                }
            }
        }

        if !currentParagraph.isEmpty {
            result.append(currentParagraph)
        }

        // Filter out empty strings and join with double newlines for paragraph breaks
        let paragraphs = result.filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
