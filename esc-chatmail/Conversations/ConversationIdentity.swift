import Foundation
import CryptoKit

struct ConversationIdentity {
    let key: String          // "list|<list-id>" OR "a@x|b@y|c@z"
    let keyHash: String      // SHA256 hex of key
    let type: ConversationType
    let participants: [String] // normalized, excluding "me" (empty for .list)
}

func normalizedEmail(_ raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let at = s.firstIndex(of: "@") else { return s }
    var local = String(s[..<at])
    var domain = String(s[s.index(after: at)...])
    
    if domain == "googlemail.com" { 
        domain = "gmail.com" 
    }
    
    if domain == "gmail.com" {
        local = local.replacingOccurrences(of: ".", with: "")
        if let plus = local.firstIndex(of: "+") { 
            local = String(local[..<plus]) 
        }
    }
    
    return local + "@" + domain
}

func makeConversationIdentity(from headers: [MessageHeader],
                              myAliases: Set<String>) -> ConversationIdentity {
    // 1) List-Id precedence
    if let listIdHeader = headers.first(where: { $0.name.caseInsensitiveCompare("List-Id") == .orderedSame })?.value {
        let listId = listIdHeader.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "list|\(listId)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format:"%02x", $0) }.joined()
        return ConversationIdentity(key: key, keyHash: hash, type: .list, participants: [])
    }
    
    // 2) Participant set S = (From ∪ To ∪ Cc) \ myAliases (ignore Bcc)
    func values(_ h: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(h) == .orderedSame }
            .flatMap { $0.value.split(separator: ",").map(String.init) }
    }
    
    let raw = values("From") + values("To") + values("Cc")
    let parts = Set(raw.compactMap { EmailNormalizer.extractEmail(from: $0) }
                      .map(normalizedEmail)
                      .filter { !$0.isEmpty && !myAliases.contains($0) })
    let sorted = parts.sorted()
    let key = sorted.joined(separator: "|")
    let hash = SHA256.hash(data: Data(key.utf8)).map { String(format:"%02x", $0) }.joined()
    let type: ConversationType = sorted.count <= 1 ? .oneToOne : .group
    
    return ConversationIdentity(key: key, keyHash: hash, type: type, participants: sorted)
}