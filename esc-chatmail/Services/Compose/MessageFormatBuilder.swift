import Foundation

/// Formats quoted text for forwards and replies
@MainActor
struct MessageFormatBuilder {
    let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    /// Result of formatting a forwarded message
    struct ForwardResult {
        let body: String
        let htmlBody: String?
        let subject: String?
        let attachments: [Attachment]
        let inlineAttachments: [Attachment]
    }

    func formatForwardedMessage(_ message: Message) -> ForwardResult {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        // Build forward header info
        var fromLine = ""
        let participants = Array(message.conversation?.participants ?? [])

        if message.isFromMe {
            fromLine = authSession.userEmail ?? "Me"
        } else {
            if let otherParticipant = participants.first(where: { participant in
                let email = participant.person?.email ?? ""
                return EmailNormalizer.normalize(email) != EmailNormalizer.normalize(authSession.userEmail ?? "")
            })?.person {
                fromLine = otherParticipant.name ?? otherParticipant.email
            }
        }

        let dateLine = formatter.string(from: message.internalDate)

        var subject: String?
        var subjectLine = ""
        if let originalSubject = message.subject, !originalSubject.isEmpty {
            subjectLine = originalSubject

            // Set subject with Fwd: prefix
            if originalSubject.lowercased().hasPrefix("fwd:") || originalSubject.lowercased().hasPrefix("fw:") {
                subject = originalSubject
            } else {
                subject = "Fwd: \(originalSubject)"
            }
        }

        let recipientList = participants.compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(authSession.userEmail ?? "") }

        let toLine = recipientList.joined(separator: ", ")

        // Build plain text forward header
        var quotedText = "\n\n---------- Forwarded message ---------\n"
        quotedText += "From: \(fromLine)\n"
        quotedText += "Date: \(dateLine)\n"
        if !subjectLine.isEmpty {
            quotedText += "Subject: \(subjectLine)\n"
        }
        if !toLine.isEmpty {
            quotedText += "To: \(toLine)\n"
        }
        quotedText += "\n"

        // Use full body text if available, otherwise fall back to snippet
        let messageContent = message.bodyTextValue ?? message.snippet ?? ""
        quotedText += messageContent

        // Load HTML content if available
        var htmlBody: String?
        if let originalHTML = HTMLContentHandler.shared.loadHTML(for: message.id) {
            htmlBody = buildHTMLForward(
                originalHTML: originalHTML,
                from: fromLine,
                date: dateLine,
                subject: subjectLine,
                to: toLine
            )
        }

        // Separate inline attachments (those with contentId) from regular attachments
        let allAttachments = message.attachmentsArray
        let inlineAttachments = allAttachments.filter { $0.contentId != nil && !$0.contentId!.isEmpty }
        let regularAttachments = allAttachments.filter { $0.contentId == nil || $0.contentId!.isEmpty }

        return ForwardResult(
            body: quotedText,
            htmlBody: htmlBody,
            subject: subject,
            attachments: regularAttachments,
            inlineAttachments: inlineAttachments
        )
    }

    /// Builds HTML content for forwarded message with proper header styling
    private func buildHTMLForward(originalHTML: String, from: String, date: String, subject: String, to: String) -> String {
        let headerHTML = """
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; \
        padding: 10px 0; margin: 20px 0; border-left: 2px solid #ccc; padding-left: 10px; color: #555;">
        <div style="margin-bottom: 5px;"><strong>---------- Forwarded message ---------</strong></div>
        <div><strong>From:</strong> \(escapeHTML(from))</div>
        <div><strong>Date:</strong> \(escapeHTML(date))</div>
        \(subject.isEmpty ? "" : "<div><strong>Subject:</strong> \(escapeHTML(subject))</div>")
        \(to.isEmpty ? "" : "<div><strong>To:</strong> \(escapeHTML(to))</div>")
        </div>
        <hr style="border: none; border-top: 1px solid #ccc; margin: 10px 0;">
        """

        // Insert the forward header into the original HTML
        // Try to insert after <body> tag if it exists, otherwise prepend
        let bodyTagPattern = try? NSRegularExpression(pattern: "<body[^>]*>", options: .caseInsensitive)

        if let match = bodyTagPattern?.firstMatch(in: originalHTML, range: NSRange(originalHTML.startIndex..., in: originalHTML)),
           let range = Range(match.range, in: originalHTML) {
            // Insert header right after the <body> tag
            var modifiedHTML = originalHTML
            let insertIndex = range.upperBound
            modifiedHTML.insert(contentsOf: "\n\(headerHTML)\n", at: insertIndex)
            return modifiedHTML
        } else {
            // No body tag found - wrap minimally
            return """
            <html>
            <head><meta charset="UTF-8"></head>
            <body>
            \(headerHTML)
            \(originalHTML)
            </body>
            </html>
            """
        }
    }

    /// Escapes HTML special characters to prevent XSS
    private func escapeHTML(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    // MARK: - HTML Content Building for Send

    /// Builds the final HTML body by merging user's new content with the forwarded HTML.
    ///
    /// When forwarding, the user types their message in plain text. This method converts
    /// that text to HTML and prepends it to the forwarded HTML content so email clients
    /// render the complete message properly.
    ///
    /// - Parameters:
    ///   - userContent: The new text the user typed (will be converted to HTML)
    ///   - forwardedHTML: The original forwarded HTML content (already includes forward header)
    /// - Returns: Complete HTML with user's content prepended
    func buildFinalHTMLForForward(userContent: String, forwardedHTML: String) -> String {
        // Extract just the user's new content (everything before the forward header)
        let userMessage = extractUserContent(from: userContent)

        // If user didn't add any content, return the forwarded HTML as-is
        if userMessage.isEmpty {
            return forwardedHTML
        }

        // Convert user's plain text to HTML
        let userHTML = convertPlainTextToHTML(userMessage)

        // Insert user's content at the beginning of the body
        return insertContentAfterBodyTag(content: userHTML, into: forwardedHTML)
    }

    /// Generates a complete HTML document from plain text when no HTML version exists.
    ///
    /// This is used when forwarding an email that only has plain text content.
    /// The generated HTML:
    /// - Preserves whitespace and line breaks
    /// - Auto-links URLs
    /// - Uses a readable font stack
    ///
    /// - Parameters:
    ///   - plainText: The complete plain text content (user message + forwarded text)
    /// - Returns: A complete HTML document
    func generateHTMLFromPlainText(_ plainText: String) -> String {
        let htmlContent = convertPlainTextToHTML(plainText)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            font-size: 14px;
            line-height: 1.5;
            color: #333;
            margin: 0;
            padding: 0;
        }
        </style>
        </head>
        <body>
        \(htmlContent)
        </body>
        </html>
        """
    }

    /// Extracts the user's new content from the full plain text body.
    ///
    /// The plain text body contains the user's new message followed by the forwarded
    /// message header. This extracts just the user's portion.
    private func extractUserContent(from fullBody: String) -> String {
        // Find the forward header separator
        let forwardMarkers = [
            "---------- Forwarded message ---------",
            "---------- Forwarded message ----------",
            "----- Forwarded message -----"
        ]

        for marker in forwardMarkers {
            if let range = fullBody.range(of: marker) {
                let userPart = String(fullBody[..<range.lowerBound])
                return userPart.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // No forward marker found - this shouldn't happen for forwards
        return ""
    }

    /// Converts plain text to HTML, preserving formatting and auto-linking URLs.
    private func convertPlainTextToHTML(_ text: String) -> String {
        // First escape HTML characters
        var html = escapeHTML(text)

        // Auto-link URLs
        html = autoLinkURLs(html)

        // Convert line breaks to proper HTML
        // Use <br> tags to preserve line breaks
        html = html.replacingOccurrences(of: "\r\n", with: "\n")
        html = html.replacingOccurrences(of: "\r", with: "\n")

        // Split into paragraphs on double newlines
        let paragraphs = html.components(separatedBy: "\n\n")
        if paragraphs.count > 1 {
            // Multiple paragraphs - wrap each in <p> tags
            html = paragraphs
                .map { paragraph in
                    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return "" }
                    // Convert single newlines to <br> within paragraphs
                    let withBreaks = trimmed.replacingOccurrences(of: "\n", with: "<br>\n")
                    return "<p style=\"margin: 0 0 1em 0;\">\(withBreaks)</p>"
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            // Single paragraph - just convert newlines to <br>
            html = html.replacingOccurrences(of: "\n", with: "<br>\n")
            html = "<div style=\"margin: 0;\">\(html)</div>"
        }

        return html
    }

    /// Auto-links URLs in HTML-escaped text.
    ///
    /// Finds URLs and wraps them in anchor tags. Works on already HTML-escaped text.
    private func autoLinkURLs(_ text: String) -> String {
        // URL pattern that works with HTML-escaped text
        // Matches http://, https://, and www. URLs
        let urlPattern = #"(https?://[^\s<>&\"']+|www\.[^\s<>&\"']+)"#

        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Process matches in reverse order to preserve indices
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let url = String(result[range])

            // Add protocol if missing (for www. URLs)
            let href = url.lowercased().hasPrefix("http") ? url : "https://\(url)"

            // Create anchor tag
            let link = "<a href=\"\(href)\" style=\"color: #007AFF; text-decoration: none;\">\(url)</a>"

            result.replaceSubrange(range, with: link)
        }

        return result
    }

    /// Inserts HTML content after the body tag in an existing HTML document.
    private func insertContentAfterBodyTag(content: String, into html: String) -> String {
        let bodyTagPattern = try? NSRegularExpression(pattern: "<body[^>]*>", options: .caseInsensitive)

        if let match = bodyTagPattern?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range, in: html) {
            var modifiedHTML = html
            let insertIndex = range.upperBound
            // Add user content followed by a spacing div
            let spacedContent = "\n\(content)\n<div style=\"margin-bottom: 20px;\"></div>\n"
            modifiedHTML.insert(contentsOf: spacedContent, at: insertIndex)
            return modifiedHTML
        } else {
            // No body tag - wrap the whole thing
            return """
            <!DOCTYPE html>
            <html>
            <head><meta charset="UTF-8"></head>
            <body>
            \(content)
            <div style="margin-bottom: 20px;"></div>
            \(html)
            </body>
            </html>
            """
        }
    }
}
