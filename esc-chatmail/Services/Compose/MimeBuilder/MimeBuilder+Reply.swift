import Foundation

// MARK: - Reply Formatting
extension MimeBuilder {
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

    static func base64UrlEncode(_ data: Data) -> String {
        var base64 = data.base64EncodedString()
        base64 = base64.replacingOccurrences(of: "+", with: "-")
        base64 = base64.replacingOccurrences(of: "/", with: "_")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        return base64
    }
}
