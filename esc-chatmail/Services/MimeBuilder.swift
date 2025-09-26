import Foundation

struct AttachmentData {
    let data: Data
    let filename: String
    let mimeType: String
}

struct QuotedMessage {
    let senderName: String?
    let senderEmail: String
    let date: Date
    let body: String?
}

struct MimeBuilder {
    
    static func buildNew(to: [String], from: String, fromName: String? = nil, body: String, subject: String? = nil, attachments: [AttachmentData] = []) -> Data {
        if attachments.isEmpty {
            return buildSimpleMessage(to: to, from: from, fromName: fromName, body: body, subject: subject, inReplyTo: nil, references: [])
        } else {
            return buildMultipartMessage(to: to, from: from, fromName: fromName, body: body, subject: subject, inReplyTo: nil, references: [], attachments: attachments)
        }
    }
    
    static func buildReply(
        to: [String],
        from: String,
        fromName: String? = nil,
        body: String,
        subject: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage? = nil,
        attachments: [AttachmentData] = []
    ) -> Data {
        let bodyWithQuote = formatReplyBody(body: body, originalMessage: originalMessage)
        if attachments.isEmpty {
            return buildSimpleMessage(to: to, from: from, fromName: fromName, body: bodyWithQuote, subject: subject, inReplyTo: inReplyTo, references: references)
        } else {
            return buildMultipartMessage(to: to, from: from, fromName: fromName, body: bodyWithQuote, subject: subject, inReplyTo: inReplyTo, references: references, attachments: attachments)
        }
    }
    
    private static func buildSimpleMessage(
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
            mime += "In-Reply-To: \(inReplyTo)\r\n"
        }
        
        if !references.isEmpty {
            let referencesHeader = references.joined(separator: " ")
            mime += "References: \(referencesHeader)\r\n"
        }
        
        mime += "MIME-Version: 1.0\r\n"
        mime += "Content-Type: text/plain; charset=UTF-8\r\n"
        mime += "Content-Transfer-Encoding: 8bit\r\n"
        mime += "\r\n"
        mime += body
        
        return mime.data(using: .utf8) ?? Data()
    }
    
    private static func buildMultipartMessage(
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
            mime += "In-Reply-To: \(inReplyTo)\r\n"
        }
        
        if !references.isEmpty {
            let referencesHeader = references.joined(separator: " ")
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
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n"
            mime += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
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
    
    private static func generateBoundary() -> String {
        return "----Boundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
    
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
    
    static func generateMessageId() -> String {
        let uuid = UUID().uuidString.lowercased()
        let bundleId = Bundle.main.bundleIdentifier ?? "com.app.mail"
        let domain = bundleId.replacingOccurrences(of: ".", with: "-")
        return "<\(uuid)@\(domain)>"
    }
    
    static func encodeHeaderIfNeeded(_ text: String) -> String {
        let asciiOnly = text.unicodeScalars.allSatisfy { $0.isASCII }
        if asciiOnly {
            return text
        }

        guard let data = text.data(using: .utf8) else { return text }
        let base64 = data.base64EncodedString()
        return "=?UTF-8?B?\(base64)?="
    }

    static func formatFromHeader(email: String, name: String?) -> String {
        guard let name = name, !name.isEmpty else {
            return email
        }

        // Check if name needs encoding for non-ASCII characters
        let encodedName = encodeHeaderIfNeeded(name)

        // Format as "Name <email@example.com>"
        // If name contains special characters, quote it
        if name.contains(where: { $0 == "\"" || $0 == "<" || $0 == ">" || $0 == "," || $0 == "@" }) {
            let quotedName = name.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(quotedName)\" <\(email)>"
        } else {
            return "\(encodedName) <\(email)>"
        }
    }
    
    static func base64UrlEncode(_ data: Data) -> String {
        var base64 = data.base64EncodedString()
        base64 = base64.replacingOccurrences(of: "+", with: "-")
        base64 = base64.replacingOccurrences(of: "/", with: "_")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        return base64
    }
    
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
        if let originalBody = originalMessage.body {
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
    
    static func buildNew(to: [String], from: String, body: String) -> Data {
        return buildNew(to: to, from: from, fromName: nil, body: body, subject: nil, attachments: [])
    }

    static func buildReply(
        to: [String],
        from: String,
        body: String,
        subject: String,
        inReplyTo: String?,
        references: [String]
    ) -> Data {
        return buildReply(to: to, from: from, fromName: nil, body: body, subject: subject, inReplyTo: inReplyTo, references: references, originalMessage: nil, attachments: [])
    }
}