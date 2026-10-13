import Foundation

/// Formats quoted text for forwards and replies
@MainActor
struct MessageFormatBuilder {
    struct ForwardSource {
        struct Participant {
            let email: String
            let displayName: String?
        }

        let id: String
        let subject: String?
        let internalDate: Date
        let sender: Participant?
        let bodyText: String?
        let snippet: String?
        let originalHTML: String?
        let to: [Participant]
        let cc: [Participant]
        var rawToHeader: String? = nil
        var rawCcHeader: String? = nil
    }

    let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    /// Result of formatting a forwarded message
    struct ForwardResult {
        let body: String
        let htmlBody: String?
        let subject: String?
    }

    func formatForwardedMessage(_ source: ForwardSource) -> ForwardResult {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let fromLine = source.sender.map(formattedMailbox) ?? PersonDisplayNameResolver.fallbackSenderName()
        let dateLine = formatter.string(from: source.internalDate)

        var subject: String?
        var subjectLine = ""
        if let originalSubject = source.subject, !originalSubject.isEmpty {
            subjectLine = originalSubject

            // Set subject with Fwd: prefix
            if originalSubject.lowercased().hasPrefix("fwd:") || originalSubject.lowercased().hasPrefix("fw:") {
                subject = originalSubject
            } else {
                subject = "Fwd: \(originalSubject)"
            }
        }

        let toLine = source.rawToHeader.map(formattedRecipientHeader)
            ?? source.to.map(formattedMailbox).joined(separator: ", ")
        let ccLine = source.rawCcHeader.map(formattedRecipientHeader)
            ?? source.cc.map(formattedMailbox).joined(separator: ", ")

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
        if !ccLine.isEmpty {
            quotedText += "Cc: \(ccLine)\n"
        }
        quotedText += "\n"

        // Use full body text if available, otherwise fall back to snippet
        let messageContent = MessagePreviewText.nonEmpty(source.bodyText) == nil
            ? source.snippet ?? ""
            : source.bodyText ?? ""
        quotedText += messageContent

        // Load HTML content if available
        var htmlBody: String?
        if let originalHTML = source.originalHTML {
            htmlBody = buildHTMLForward(
                originalHTML: originalHTML,
                from: fromLine,
                date: dateLine,
                subject: subjectLine,
                to: toLine,
                cc: ccLine
            )
        }

        return ForwardResult(
            body: quotedText,
            htmlBody: htmlBody,
            subject: subject
        )
    }

    private func formattedMailbox(_ participant: ForwardSource.Participant) -> String {
        let email = participant.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayName = MessagePreviewText.nonEmpty(participant.displayName) else {
            return email
        }
        guard !email.isEmpty else { return displayName }

        return "\(formattedDisplayPhrase(displayName)) <\(email)>"
    }

    private func formattedDisplayPhrase(_ displayName: String) -> String {
        if displayName.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"<>\\:;@()[]")) != nil {
            let escapedName = displayName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escapedName)\""
        }
        return displayName
    }

    /// Keep address groups and their separators intact; decode names only after
    /// identifying the raw header structure so decoded punctuation stays in names.
    private func formattedRecipientHeader(_ rawHeader: String) -> String {
        var result = ""
        var segmentStart = rawHeader.startIndex
        var index = segmentStart
        var isInsideQuotes = false
        var isEscaped = false
        var angleDepth = 0
        var commentDepth = 0
        var domainLiteralDepth = 0

        while index < rawHeader.endIndex {
            let character = rawHeader[index]
            let nextIndex = rawHeader.index(after: index)
            if isEscaped {
                isEscaped = false
            } else if rawHeader[index...].hasPrefix("=?"),
                      let encodedEnd = rawHeader.range(of: "?=", range: nextIndex..<rawHeader.endIndex) {
                index = encodedEnd.upperBound
                continue
            } else if character == "\\", isInsideQuotes || commentDepth > 0 || domainLiteralDepth > 0 {
                isEscaped = true
            } else if commentDepth > 0 {
                if character == "(" { commentDepth += 1 }
                if character == ")" { commentDepth -= 1 }
            } else if domainLiteralDepth > 0 {
                if character == "]" { domainLiteralDepth -= 1 }
            } else if character == "\"" {
                isInsideQuotes.toggle()
            } else if !isInsideQuotes {
                switch character {
                case "(": commentDepth += 1
                case "[": domainLiteralDepth += 1
                case "<": angleDepth += 1
                case ">": angleDepth = max(0, angleDepth - 1)
                case ",", ":", ";":
                    if angleDepth == 0 {
                        result += formattedRecipientSegment(
                            String(rawHeader[segmentStart..<index]),
                            isGroupName: character == ":"
                        )
                        result.append(character)
                        segmentStart = nextIndex
                    }
                default: break
                }
            }
            index = nextIndex
        }

        result += formattedRecipientSegment(String(rawHeader[segmentStart...]), isGroupName: false)
        return result
    }

    private func formattedRecipientSegment(_ rawSegment: String, isGroupName: Bool) -> String {
        // Ordinary and unparseable spans remain verbatim, including empty groups,
        // comments, quoted local parts, and address spellings.
        guard RFC2047Decoder.containsEncodedWord(rawSegment) else { return rawSegment }
        let value = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatted: String
        if isGroupName {
            guard value.rangeOfCharacter(from: CharacterSet(charactersIn: "()\"")) == nil else {
                return rawSegment
            }
            formatted = formattedDisplayPhrase(RFC2047Decoder.decode(value))
        } else if value.filter({ $0 == "<" }).count == 1,
                  value.filter({ $0 == ">" }).count == 1,
                  let email = EmailNormalizer.extractEmail(from: value),
                  let addressRange = value.range(of: "<\(email)>"),
                  value[..<addressRange.lowerBound].rangeOfCharacter(from: CharacterSet(charactersIn: "()\"")) == nil,
                  RFC2047Decoder.containsEncodedWord(String(value[..<addressRange.lowerBound])),
                  let name = EmailNormalizer.extractDisplayName(from: String(value[..<addressRange.upperBound])) {
            formatted = formattedMailbox(.init(email: email, displayName: name))
                + String(value[addressRange.upperBound...])
        } else {
            return rawSegment
        }
        return String(rawSegment.prefix(while: { $0.isWhitespace })) + formatted
            + String(rawSegment.reversed().prefix(while: { $0.isWhitespace }).reversed())
    }

    /// Builds HTML content for forwarded message with proper header styling
    private func buildHTMLForward(originalHTML: String, from: String, date: String, subject: String, to: String, cc: String) -> String {
        let headerHTML = """
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; \
        padding: 10px 0; margin: 20px 0; border-left: 2px solid #ccc; padding-left: 10px; color: #555;">
        <div style="margin-bottom: 5px;"><strong>---------- Forwarded message ---------</strong></div>
        <div><strong>From:</strong> \(escapeHTML(from))</div>
        <div><strong>Date:</strong> \(escapeHTML(date))</div>
        \(subject.isEmpty ? "" : "<div><strong>Subject:</strong> \(escapeHTML(subject))</div>")
        \(to.isEmpty ? "" : "<div><strong>To:</strong> \(escapeHTML(to))</div>")
        \(cc.isEmpty ? "" : "<div><strong>Cc:</strong> \(escapeHTML(cc))</div>")
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
        let userMessage = userContent.trimmingCharacters(in: .whitespacesAndNewlines)

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

    /// Converts plain text to HTML, preserving formatting and auto-linking URLs.
    private func convertPlainTextToHTML(_ text: String) -> String {
        var html = autoLinkURLs(text)

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

    /// Detects links in plain text, then escapes each link and surrounding text for HTML.
    private func autoLinkURLs(_ text: String) -> String {
        let urlPattern = #"(https?://[^\s<>\"']+|www\.[^\s<>\"']+)"#

        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return escapeHTML(text)
        }

        var result = ""
        var cursor = text.startIndex
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += escapeHTML(String(text[cursor..<range.lowerBound]))
            let url = String(text[range])

            // Add protocol if missing (for www. URLs)
            let href = url.lowercased().hasPrefix("http") ? url : "https://\(url)"

            // Create anchor tag
            result += "<a href=\"\(escapeHTML(href))\" style=\"color: #007AFF; text-decoration: none;\">\(escapeHTML(url))</a>"
            cursor = range.upperBound
        }

        result += escapeHTML(String(text[cursor...]))
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
