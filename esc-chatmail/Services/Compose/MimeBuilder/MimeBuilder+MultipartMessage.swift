import Foundation

// MARK: - Multipart Message Building
extension MimeBuilder {
    static func buildMultipartMessage(
        to: [String],
        from: String,
        fromName: String?,
        body: String,
        subject: String?,
        inReplyTo: String?,
        references: [String],
        attachments: [AttachmentData]
    ) -> Data {
        var mime = ""
        let boundary = generateBoundary()

        // Headers
        let fromHeader = formatFromHeader(email: from, name: fromName)
        mime += "From: \(fromHeader)\r\n"
        mime += "To: \(to.joined(separator: ", "))\r\n"

        if let subject = subject, !subject.isEmpty {
            let encodedSubject = encodeHeaderIfNeeded(subject)
            mime += "Subject: \(encodedSubject)\r\n"
        } else {
            // Add default subject if none provided
            mime += "Subject: (No Subject)\r\n"
        }

        mime += "Date: \(formatDate(Date()))\r\n"
        mime += "Message-ID: \(generateMessageId())\r\n"

        if let inReplyTo = inReplyTo, !inReplyTo.isEmpty {
            mime += "In-Reply-To: \(sanitizeHeaderValue(inReplyTo))\r\n"
        }

        if !references.isEmpty {
            let referencesHeader = references.map { sanitizeHeaderValue($0) }.joined(separator: " ")
            mime += "References: \(referencesHeader)\r\n"
        }

        mime += "MIME-Version: 1.0\r\n"
        mime += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n"
        mime += "\r\n"

        // Text part
        mime += "--\(boundary)\r\n"
        mime += "Content-Type: text/plain; charset=UTF-8\r\n"
        mime += "Content-Transfer-Encoding: 8bit\r\n"
        mime += "\r\n"
        mime += body
        mime += "\r\n"

        // Attachments
        for attachment in attachments {
            let safeFilename = sanitizeHeaderValue(attachment.filename)
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: \(sanitizeHeaderValue(attachment.mimeType)); name=\"\(safeFilename)\"\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "Content-Disposition: attachment; filename=\"\(safeFilename)\"\r\n"
            mime += "\r\n"

            // Convert to standard base64 (not base64url)
            let base64String = attachment.data.base64EncodedString(options: .lineLength64Characters)
            mime += base64String
            mime += "\r\n"
        }

        // Closing boundary
        mime += "--\(boundary)--\r\n"

        return mime.data(using: .utf8) ?? Data()
    }

    static func generateBoundary() -> String {
        return "----Boundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
