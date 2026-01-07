import Foundation

// MARK: - Header Formatting & Encoding
extension MimeBuilder {
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

    /// Sanitizes header values to prevent CRLF injection attacks
    static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func encodeHeaderIfNeeded(_ text: String) -> String {
        let sanitized = sanitizeHeaderValue(text)
        let asciiOnly = sanitized.unicodeScalars.allSatisfy { $0.isASCII }
        if asciiOnly {
            return sanitized
        }

        guard let data = sanitized.data(using: .utf8) else { return sanitized }
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
}
