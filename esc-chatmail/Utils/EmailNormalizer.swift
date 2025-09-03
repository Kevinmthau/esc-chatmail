import Foundation

class EmailNormalizer {
    static func normalize(_ email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard let atIndex = trimmed.firstIndex(of: "@") else {
            return trimmed
        }
        
        let localPart = String(trimmed[..<atIndex])
        let domain = String(trimmed[trimmed.index(after: atIndex)...])
        
        if domain == "gmail.com" || domain == "googlemail.com" {
            var normalizedLocal = localPart.replacingOccurrences(of: ".", with: "")
            
            if let plusIndex = normalizedLocal.firstIndex(of: "+") {
                normalizedLocal = String(normalizedLocal[..<plusIndex])
            }
            
            return "\(normalizedLocal)@gmail.com"
        }
        
        return trimmed
    }
    
    static func extractEmail(from string: String) -> String? {
        let pattern = #"<([^>]+@[^>]+)>"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
           let range = Range(match.range(at: 1), in: string) {
            return String(string[range])
        }
        
        if string.contains("@") {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    static func extractAllEmails(from string: String) -> [String] {
        var emails: [String] = []
        
        // Split by comma to handle multiple recipients
        let recipients = string.split(separator: ",")
        
        for recipient in recipients {
            let recipientStr = String(recipient).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Extract email from "Name <email>" format
            let pattern = #"<([^>]+@[^>]+)>"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: recipientStr, range: NSRange(recipientStr.startIndex..., in: recipientStr)),
               let range = Range(match.range(at: 1), in: recipientStr) {
                emails.append(String(recipientStr[range]))
            } else if recipientStr.contains("@") {
                // Plain email address
                emails.append(recipientStr)
            }
        }
        
        return emails
    }
    
    static func extractDisplayName(from string: String) -> String? {
        if let emailStartIndex = string.firstIndex(of: "<") {
            let name = String(string[..<emailStartIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name.replacingOccurrences(of: "\"", with: "")
        }
        return nil
    }
}