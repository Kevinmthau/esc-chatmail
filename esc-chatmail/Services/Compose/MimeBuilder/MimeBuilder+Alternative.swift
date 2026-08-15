import Foundation

// MARK: - Alternative Message Building (HTML + Plain Text)
extension MimeBuilder {

    /// Builds a MIME message with multipart/alternative structure for HTML content.
    ///
    /// Structure when inline attachments exist:
    /// ```
    /// multipart/mixed
    /// ├── multipart/related
    /// │   ├── multipart/alternative
    /// │   │   ├── text/plain
    /// │   │   └── text/html
    /// │   └── inline images (with Content-ID)
    /// └── regular attachments
    /// ```
    ///
    /// Structure without inline attachments:
    /// ```
    /// multipart/mixed
    /// ├── multipart/alternative
    /// │   ├── text/plain
    /// │   └── text/html
    /// └── regular attachments
    /// ```
    static func buildAlternativeMessage(
        to: [String],
        from: String,
        fromName: String?,
        body: String,
        htmlBody: String,
        subject: String?,
        inReplyTo: String?,
        references: [String],
        attachments: [AttachmentData],
        inlineAttachments: [InlineAttachmentData],
        messageId: String? = nil
    ) -> Data {
        // Rich HTML and its inline parts are one unit. If a Content-ID would
        // need a lossy rewrite, fall back to the plain body so its `cid:` URL
        // cannot diverge from the emitted part header.
        guard inlineAttachments.allSatisfy({ canEmitContentIdVerbatim($0.contentId) }) else {
            if attachments.isEmpty {
                return buildSimpleMessage(
                    to: to,
                    from: from,
                    fromName: fromName,
                    body: body,
                    subject: subject,
                    inReplyTo: inReplyTo,
                    references: references,
                    messageId: messageId
                )
            }
            return buildMultipartMessage(
                to: to,
                from: from,
                fromName: fromName,
                body: body,
                subject: subject,
                inReplyTo: inReplyTo,
                references: references,
                attachments: attachments,
                messageId: messageId
            )
        }

        var mime = ""
        let mixedBoundary = generateBoundary()
        let relatedBoundary = generateBoundary()
        let alternativeBoundary = generateBoundary()

        // Headers
        let fromHeader = formatFromHeader(email: from, name: fromName)
        mime += "From: \(fromHeader)\r\n"
        mime += "To: \(to.map { sanitizeHeaderValue($0) }.joined(separator: ", "))\r\n"

        if let subject = subject, !subject.isEmpty {
            let encodedSubject = encodeHeaderIfNeeded(subject)
            mime += "Subject: \(encodedSubject)\r\n"
        } else {
            mime += "Subject: (No Subject)\r\n"
        }

        mime += "Date: \(formatDate(Date()))\r\n"
        mime += "Message-ID: \(sanitizeHeaderValue(messageId ?? generateMessageId()))\r\n"

        if let inReplyTo = inReplyTo, !inReplyTo.isEmpty {
            mime += "In-Reply-To: \(sanitizeHeaderValue(inReplyTo))\r\n"
        }

        if !references.isEmpty {
            let referencesHeader = references.map { sanitizeHeaderValue($0) }.joined(separator: " ")
            mime += "References: \(referencesHeader)\r\n"
        }

        mime += "MIME-Version: 1.0\r\n"

        // Determine structure based on whether we have attachments or inline images
        let hasAttachments = !attachments.isEmpty
        let hasInlineAttachments = !inlineAttachments.isEmpty

        if hasAttachments || hasInlineAttachments {
            // Need multipart/mixed as outer wrapper
            mime += "Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"\r\n"
            mime += "\r\n"

            mime += "--\(mixedBoundary)\r\n"

            if hasInlineAttachments {
                // multipart/related for HTML + inline images
                mime += "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n"
                mime += "\r\n"

                mime += "--\(relatedBoundary)\r\n"
            }

            // multipart/alternative for text + HTML
            mime += "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n"
            mime += "\r\n"

            // Plain text part - use base64 for compatibility
            mime += "--\(alternativeBoundary)\r\n"
            mime += "Content-Type: text/plain; charset=UTF-8\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "\r\n"
            if let bodyData = body.data(using: .utf8) {
                mime += bodyData.base64EncodedString(options: .lineLength76Characters)
            }
            mime += "\r\n"

            // HTML part - use base64 for maximum compatibility with email clients
            mime += "--\(alternativeBoundary)\r\n"
            mime += "Content-Type: text/html; charset=UTF-8\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "\r\n"
            if let htmlData = htmlBody.data(using: .utf8) {
                mime += htmlData.base64EncodedString(options: .lineLength76Characters)
            }
            mime += "\r\n"

            // Close alternative boundary
            mime += "--\(alternativeBoundary)--\r\n"

            if hasInlineAttachments {
                // Add inline attachments
                for attachment in inlineAttachments {
                    mime += "--\(relatedBoundary)\r\n"
                    mime += attachmentPartHeaders(
                        mimeType: attachment.mimeType,
                        filename: attachment.filename,
                        contentId: attachment.contentId
                    )

                    let base64String = attachment.data.base64EncodedString(options: .lineLength64Characters)
                    mime += base64String
                    mime += "\r\n"
                }

                // Close related boundary
                mime += "--\(relatedBoundary)--\r\n"
            }

            // Add regular attachments
            for attachment in attachments {
                mime += "--\(mixedBoundary)\r\n"
                mime += attachmentPartHeaders(
                    mimeType: attachment.mimeType,
                    filename: attachment.filename,
                    contentId: nil
                )

                let base64String = attachment.data.base64EncodedString(options: .lineLength64Characters)
                mime += base64String
                mime += "\r\n"
            }

            // Close mixed boundary
            mime += "--\(mixedBoundary)--\r\n"

        } else {
            // No attachments - simple multipart/alternative
            mime += "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n"
            mime += "\r\n"

            // Plain text part - use base64 for compatibility
            mime += "--\(alternativeBoundary)\r\n"
            mime += "Content-Type: text/plain; charset=UTF-8\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "\r\n"
            if let bodyData = body.data(using: .utf8) {
                mime += bodyData.base64EncodedString(options: .lineLength76Characters)
            }
            mime += "\r\n"

            // HTML part - use base64 for maximum compatibility with email clients
            mime += "--\(alternativeBoundary)\r\n"
            mime += "Content-Type: text/html; charset=UTF-8\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "\r\n"
            if let htmlData = htmlBody.data(using: .utf8) {
                mime += htmlData.base64EncodedString(options: .lineLength76Characters)
            }
            mime += "\r\n"

            // Close alternative boundary
            mime += "--\(alternativeBoundary)--\r\n"
        }

        return mime.data(using: .utf8) ?? Data()
    }
}
