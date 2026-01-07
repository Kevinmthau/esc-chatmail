import Foundation

// MARK: - Simple Message Building
extension MimeBuilder {
    static func buildSimpleMessage(
        to: [String],
        from: String,
        fromName: String?,
        body: String,
        subject: String?,
        inReplyTo: String?,
        references: [String]
    ) -> Data {
        var mime = ""

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
        mime += "Content-Type: text/plain; charset=UTF-8\r\n"
        mime += "Content-Transfer-Encoding: 8bit\r\n"
        mime += "\r\n"
        mime += body

        return mime.data(using: .utf8) ?? Data()
    }
}
