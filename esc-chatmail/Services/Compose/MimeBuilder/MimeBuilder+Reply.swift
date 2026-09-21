import Foundation

// MARK: - Reply Formatting
extension MimeBuilder {
    static func prefixSubjectForReply(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        if trimmed.lowercased().hasPrefix("re:") {
            return trimmed
        }

        return "Re: \(trimmed)"
    }

    static func formatReplyBody(body: String, originalMessage: QuotedMessage?) -> String {
        guard let originalMessage = originalMessage else {
            return body
        }

        let originalBodyForQuote = prepareOriginalBodyForQuote(originalMessage.body)

        var formattedBody = body

        // Add a blank line after the new message
        if !body.isEmpty {
            formattedBody += "\r\n\r\n"
        }

        // Add attribution line
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: originalMessage.date)

        let senderDisplay = originalMessage.senderName ?? originalMessage.senderEmail
        formattedBody += "On \(dateString), \(senderDisplay) wrote:\r\n"

        // Quote the original message
        if let originalBody = originalBodyForQuote {
            // Split the original message into lines and prefix each with "> "
            let lines = originalBody.components(separatedBy: .newlines)
            for line in lines {
                formattedBody += "> \(line)\r\n"
            }
        } else {
            formattedBody += "> [Original message text not available]\r\n"
        }

        return formattedBody
    }

    static func formatReplyHTMLBody(body: String, originalMessage: QuotedMessage?) -> String {
        guard let originalMessage = originalMessage else {
            return wrapReplyHTMLDocument(contentHTML: convertPlainTextToReplyHTML(body))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: originalMessage.date)
        let senderDisplay = originalMessage.senderName ?? originalMessage.senderEmail

        if let originalHTML = prepareOriginalHTMLForQuote(originalMessage.originalHTML),
           canQuoteOriginalHTMLDocument(originalHTML) {
            return buildReplyHTMLWithOriginalDocument(
                body: body,
                originalHTML: originalHTML,
                dateString: dateString,
                senderDisplay: senderDisplay
            )
        }

        let originalBodyForQuote = prepareOriginalBodyForQuote(originalMessage.body)
        let newMessageHTML = convertPlainTextToReplyHTML(body)
        let quoteContentHTML = convertPlainTextToReplyHTML(originalBodyForQuote ?? "[Original message text not available]")
        let attributionHTML = "<div style=\"margin: 14px 0 6px 0; color: #666;\">On \(escapeHTML(dateString)), \(escapeHTML(senderDisplay)) wrote:</div>"
        let quoteBlockHTML = "<blockquote style=\"margin: 0; padding: 0 0 0 12px; border-left: 2px solid #dadce0; color: #555;\">\(quoteContentHTML)</blockquote>"

        let combinedHTML: String
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedHTML = "\(attributionHTML)\(quoteBlockHTML)"
        } else {
            combinedHTML = "\(newMessageHTML)<div style=\"height: 10px;\"></div>\(attributionHTML)\(quoteBlockHTML)"
        }

        return wrapReplyHTMLDocument(contentHTML: combinedHTML)
    }

    private static func buildReplyHTMLWithOriginalDocument(
        body: String,
        originalHTML: String,
        dateString: String,
        senderDisplay: String
    ) -> String {
        // Email bodies often reset inherited typography (including font-size: 0).
        // Give the authored response its own readable baseline while leaving the
        // quoted document's styling intact.
        let userMessageHTML = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : """
            <div class="esc-reply-content" style="font: 14px/1.5 -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #222; background-color: #fff; text-align: left;">\(convertPlainTextToReplyHTML(body))</div><div style="height: 10px;"></div>
            """
        let gmailQuotePrefix = """
        \(userMessageHTML)<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On \(escapeHTML(dateString)), \(escapeHTML(senderDisplay)) wrote:<br></div><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex;">
        """
        let gmailQuoteSuffix = "</blockquote></div>"

        if let bodyTagRange = firstBodyTagRange(in: originalHTML) {
            let prefixInsertionOffset = originalHTML.distance(
                from: originalHTML.startIndex,
                to: bodyTagRange.upperBound
            )
            var modifiedHTML = originalHTML
            let prefixInsertionIndex = modifiedHTML.index(
                modifiedHTML.startIndex,
                offsetBy: prefixInsertionOffset
            )
            modifiedHTML.insert(contentsOf: gmailQuotePrefix, at: prefixInsertionIndex)
            if let closingBodyRange = modifiedHTML.range(
                of: "</body>",
                options: [.caseInsensitive, .backwards]
            ) {
                modifiedHTML.insert(contentsOf: gmailQuoteSuffix, at: closingBodyRange.lowerBound)
            } else {
                modifiedHTML.append(gmailQuoteSuffix)
            }
            return modifiedHTML
        }

        return wrapReplyHTMLDocument(
            contentHTML: "\(gmailQuotePrefix)\(originalHTML)\(gmailQuoteSuffix)"
        )
    }

    private static func prepareOriginalBodyForQuote(_ body: String?) -> String? {
        guard let body = body else { return nil }
        let stripped = PlainTextQuoteRemover.removeQuotes(from: body)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = stripped, !stripped.isEmpty {
            return stripped
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func prepareOriginalHTMLForQuote(_ html: String?) -> String? {
        guard let trimmed = html?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let stripped = HTMLQuoteRemover.removeQuotes(from: trimmed)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stripped.isEmpty else {
            return nil
        }

        return stripped
    }

    private static func convertPlainTextToReplyHTML(_ text: String) -> String {
        let linked = autoLinkURLs(text)
        let normalized = linked
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")

        if paragraphs.count > 1 {
            return paragraphs
                .map { paragraph in
                    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return "" }
                    let withBreaks = trimmed.replacingOccurrences(of: "\n", with: "<br>\n")
                    return "<p style=\"margin: 0 0 0.9em 0;\">\(withBreaks)</p>"
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        let withBreaks = normalized.replacingOccurrences(of: "\n", with: "<br>\n")
        return "<div style=\"margin: 0;\">\(withBreaks)</div>"
    }

    private static func firstBodyTagRange(in html: String) -> Range<String.Index>? {
        guard let bodyTagPattern = try? NSRegularExpression(pattern: "<body[^>]*>", options: .caseInsensitive),
              let match = bodyTagPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else {
            return nil
        }

        return range
    }

    private static func canQuoteOriginalHTMLDocument(_ html: String) -> Bool {
        guard !html.isEmpty else {
            return false
        }

        // Replies do not currently carry the original message's inline CID parts.
        // Falling back to text quoting is safer than emitting broken cid: placeholders.
        return html.range(of: "cid:", options: .caseInsensitive) == nil
    }

    private static func wrapReplyHTMLDocument(contentHTML: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; \
        font-size: 14px; line-height: 1.5; color: #222; margin: 0; padding: 0;">
        \(contentHTML)
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    private static let replyLinkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func autoLinkURLs(_ text: String) -> String {
        guard let replyLinkDetector else { return escapeHTML(text) }

        // Detect in the original text so query separators are part of the URL,
        // and let the system detector distinguish trailing prose punctuation.
        // Escape each resulting segment exactly once, including the href.
        var result = ""
        var cursor = text.startIndex
        let matches = replyLinkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let detectedRange = Range(match.range, in: text) else { continue }
            let range = trimmingUnmatchedClosingDelimiters(detectedRange, in: text)
            let label = String(text[range])
            let lowercased = label.lowercased()
            guard lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://") ||
                    lowercased.hasPrefix("www.") else { continue }

            result += escapeHTML(String(text[cursor..<range.lowerBound]))
            let href = lowercased.hasPrefix("www.") ? "https://\(label)" : label
            result += "<a href=\"\(escapeHTML(href))\" style=\"color: #0b57d0; text-decoration: none;\">\(escapeHTML(label))</a>"
            cursor = range.upperBound
        }
        result += escapeHTML(String(text[cursor...]))
        return result
    }

    private static func trimmingUnmatchedClosingDelimiters(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        var end = range.upperBound
        while end > range.lowerBound {
            let lastIndex = text.index(before: end)
            let closing = text[lastIndex]
            let opening: Character
            switch closing {
            case ")": opening = "("
            case "]": opening = "["
            case "}": opening = "{"
            default: return range.lowerBound..<end
            }
            let candidate = text[range.lowerBound..<end]
            guard candidate.filter({ $0 == closing }).count > candidate.filter({ $0 == opening }).count else {
                break
            }
            end = lastIndex
        }
        return range.lowerBound..<end
    }

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64UrlEncodedString()
    }
}
