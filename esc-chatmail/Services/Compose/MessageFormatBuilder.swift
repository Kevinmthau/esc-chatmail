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
}
