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

    /// Stable RFC Message-ID used to reconcile an ambiguous non-idempotent send.
    /// Hex encoding is injection-safe and preserves the optimistic ID exactly.
    static func messageId(forOptimisticMessageID optimisticMessageID: String) -> String {
        let localPart = optimisticMessageID.utf8
            .map { String(format: "%02x", $0) }
            .joined()
        let bundleId = Bundle.main.bundleIdentifier ?? "com.app.mail"
        let domain = bundleId.replacingOccurrences(of: ".", with: "-")
        return "<esc-\(localPart)@\(domain)>"
    }

    static func optimisticMessageID(from rfcMessageId: String) -> String? {
        guard rfcMessageId.hasPrefix("<esc-"),
              let atIndex = rfcMessageId.firstIndex(of: "@") else {
            return nil
        }
        let hexStart = rfcMessageId.index(rfcMessageId.startIndex, offsetBy: 5)
        let hex = rfcMessageId[hexStart..<atIndex]
        guard !hex.isEmpty,
              hex.count <= 256,
              hex.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        guard let optimisticMessageID = String(bytes: bytes, encoding: .utf8),
              messageId(forOptimisticMessageID: optimisticMessageID) == rfcMessageId else {
            return nil
        }
        return optimisticMessageID
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
        let sanitizedEmail = sanitizeHeaderValue(email)
        guard let name = name, !name.isEmpty else {
            return sanitizedEmail
        }

        // Check if name needs encoding for non-ASCII characters
        let encodedName = encodeHeaderIfNeeded(name)

        // Format as "Name <email@example.com>"
        // If name contains special characters, quote it. Quote-escaping alone cannot
        // neutralize CRLF, so the quoted-name path must sanitize before escaping.
        if name.contains(where: { $0 == "\"" || $0 == "<" || $0 == ">" || $0 == "," || $0 == "@" }) {
            let quotedName = sanitizeHeaderValue(name).replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(quotedName)\" <\(sanitizedEmail)>"
        } else {
            return "\(encodedName) <\(sanitizedEmail)>"
        }
    }
}
