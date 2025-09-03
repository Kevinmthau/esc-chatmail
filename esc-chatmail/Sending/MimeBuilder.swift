import Foundation

struct MimeBuilder {
    
    static func buildNew(to: [String], from: String, body: String) -> Data {
        var mime = ""
        
        mime += "From: \(from)\r\n"
        mime += "To: \(to.joined(separator: ", "))\r\n"
        mime += "Date: \(formatDate(Date()))\r\n"
        mime += "Message-ID: \(generateMessageId())\r\n"
        mime += "MIME-Version: 1.0\r\n"
        mime += "Content-Type: text/plain; charset=UTF-8\r\n"
        mime += "Content-Transfer-Encoding: 8bit\r\n"
        mime += "\r\n"
        mime += body
        
        return mime.data(using: .utf8) ?? Data()
    }
    
    static func buildReply(
        to: [String],
        from: String,
        body: String,
        subject: String,
        inReplyTo: String?,
        references: [String]
    ) -> Data {
        var mime = ""
        
        mime += "From: \(from)\r\n"
        mime += "To: \(to.joined(separator: ", "))\r\n"
        
        if !subject.isEmpty {
            let encodedSubject = encodeHeaderIfNeeded(subject)
            mime += "Subject: \(encodedSubject)\r\n"
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
}