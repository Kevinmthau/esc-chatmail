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

    /// Converts an email username to a formatted display name
    /// e.g., "firstname.lastname" → "Firstname Lastname"
    /// e.g., "john_doe" → "John Doe"
    static func formatAsDisplayName(email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract username part (before @)
        let username: String
        if let atIndex = trimmed.firstIndex(of: "@") {
            username = String(trimmed[..<atIndex])
        } else {
            username = trimmed
        }

        // Split on common separators (dots, underscores, hyphens)
        let parts = username
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }

        // Capitalize each part
        let capitalized = parts.map { part in
            part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }

        return capitalized.joined(separator: " ")
    }

    /// Returns true if newName is "better" than existingName
    /// Better means: more name parts, or same parts but longer
    static func isBetterDisplayName(_ newName: String?, than existingName: String?) -> Bool {
        guard let new = newName, !new.isEmpty else { return false }
        guard let existing = existingName, !existing.isEmpty else { return true }

        let newParts = new.components(separatedBy: " ").filter { !$0.isEmpty }
        let existingParts = existing.components(separatedBy: " ").filter { !$0.isEmpty }

        // More name parts is better (e.g., "John Smith" > "John")
        if newParts.count > existingParts.count { return true }
        if newParts.count < existingParts.count { return false }

        // Same number of parts: longer is better (handles middle names, titles)
        return new.count > existing.count
    }
}