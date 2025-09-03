import Foundation
import CryptoKit

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

class ConversationGrouper {
    private let myAliases: Set<String>
    
    init(myEmail: String, aliases: [String] = []) {
        var normalizedAliases = Set(aliases.map { EmailNormalizer.normalize($0) })
        normalizedAliases.insert(EmailNormalizer.normalize(myEmail))
        self.myAliases = normalizedAliases
    }
    
    func computeConversationKey(from headers: [MessageHeader]) -> (key: String, type: ConversationType, participants: Set<String>) {
        // Check for List-Id first - this takes precedence
        if let listId = extractListId(from: headers) {
            let listIdHash = sha256("list|\(listId)")
            return (listIdHash, .list, [])
        }
        
        // Extract participant set S = (From ∪ To ∪ Cc) - excluding my aliases
        // Note: Bcc is explicitly ignored for grouping
        var participants = Set<String>()
        
        for header in headers {
            let headerName = header.name.lowercased()
            
            // Only process From, To, and Cc headers (NOT Bcc)
            if headerName == "from" || headerName == "to" || headerName == "cc" {
                // Extract all emails from this header (handles comma-separated lists)
                let emails = EmailNormalizer.extractAllEmails(from: header.value)
                
                for email in emails {
                    let normalized = EmailNormalizer.normalize(email)
                    // Exclude all my aliases from the participant set
                    if !myAliases.contains(normalized) {
                        participants.insert(normalized)
                    }
                }
            }
            // Bcc is explicitly ignored - do not process it
        }
        
        // Create a deterministic key from the participant set
        // Sort to ensure order-independence
        let sortedParticipants = participants.sorted()
        let key = sortedParticipants.joined(separator: "|")
        let keyHash = sha256(key)
        
        // Determine conversation type based on participant count
        let type: ConversationType = participants.count <= 1 ? .oneToOne : .group
        
        return (keyHash, type, participants)
    }
    
    private func extractListId(from headers: [MessageHeader]) -> String? {
        for header in headers {
            if header.name.lowercased() == "list-id" {
                if let startIndex = header.value.firstIndex(of: "<"),
                   let endIndex = header.value.firstIndex(of: ">"),
                   startIndex < endIndex {
                    let listId = String(header.value[header.value.index(after: startIndex)..<endIndex])
                    return listId
                }
                return header.value
            }
        }
        return nil
    }
    
    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func isFromMe(_ fromHeader: String) -> Bool {
        guard let email = EmailNormalizer.extractEmail(from: fromHeader) else { return false }
        let normalized = EmailNormalizer.normalize(email)
        return myAliases.contains(normalized)
    }
}