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

        let originalBodyForQuote = prepareOriginalBodyForQuote(originalMessage.body)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: originalMessage.date)
        let senderDisplay = originalMessage.senderName ?? originalMessage.senderEmail

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

    private static func prepareOriginalBodyForQuote(_ body: String?) -> String? {
        guard let body = body else { return nil }
        let stripped = PlainTextQuoteRemover.removeQuotes(from: body)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stripped = stripped, !stripped.isEmpty {
            return stripped
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func convertPlainTextToReplyHTML(_ text: String) -> String {
        let escaped = escapeHTML(text)
        let linked = autoLinkURLs(escaped)
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

    private static func autoLinkURLs(_ text: String) -> String {
        let urlPattern = #"(https?://[^\s<>&\"']+|www\.[^\s<>&\"']+)"#
        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let url = String(result[range])
            let href = url.lowercased().hasPrefix("http") ? url : "https://\(url)"
            let link = "<a href=\"\(href)\" style=\"color: #0b57d0; text-decoration: none;\">\(url)</a>"
            result.replaceSubrange(range, with: link)
        }
        return result
    }

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64UrlEncodedString()
    }
}
