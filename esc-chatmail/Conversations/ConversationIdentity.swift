import Foundation
import CryptoKit

struct ConversationIdentity {
    let key: String          // "p|alice@example.com" (one-to-one) OR "p|alice@x|bob@y" (group)
    let keyHash: String      // SHA256 hex of key
    let type: ConversationType
    let participants: [String] // normalized emails, excluding "me"
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

/// Creates a conversation identity using PARTICIPANT-BASED grouping (iMessage-style).
/// All messages with the same set of participants are grouped into one conversation.
///
/// This provides:
/// - All emails from alice@example.com → one conversation
/// - All emails between you, alice, and bob → one group conversation
/// - Messages displayed chronologically within each conversation (like iMessage)
///
/// Key format: "p|<sorted-participants>" where participants excludes the current user
func makeConversationIdentity(from headers: [MessageHeader],
                              gmThreadId: String,
                              myAliases: Set<String>) -> ConversationIdentity {
    // Extract all participants from From, To, Cc headers
    // BCC is explicitly excluded for both identity and display
    func extractParticipants() -> [String] {
        func values(_ h: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(h) == .orderedSame }
                .flatMap { $0.value.split(separator: ",").map(String.init) }
        }

        let raw = values("From") + values("To") + values("Cc")
        // Note: BCC is intentionally excluded
        let allEmails = Set(raw.compactMap { EmailNormalizer.extractEmail(from: $0) }
                          .map(normalizedEmail)
                          .filter { !$0.isEmpty })

        // Remove current user's aliases from participants
        let parts = allEmails.filter { !myAliases.contains($0) }

        if parts.isEmpty {
            // Self-conversation: use deterministic alias selection (sorted order)
            if let firstAlias = myAliases.sorted().first {
                return [firstAlias]
            } else if let firstEmail = allEmails.sorted().first {
                return [firstEmail]
            } else {
                return ["unknown@email.com"]
            }
        } else {
            return parts.sorted()
        }
    }

    let participants = extractParticipants()
    let type: ConversationType = participants.count <= 1 ? .oneToOne : .group

    // Create participant-based key (iMessage-style grouping)
    // All messages with the same participants go into one conversation
    let key = "p|\(participants.joined(separator: "|"))"
    let hash = SHA256.hash(data: Data(key.utf8)).map { String(format:"%02x", $0) }.joined()

    #if DEBUG
    let fromHeader = headers.first(where: { $0.name.caseInsensitiveCompare("From") == .orderedSame })?.value ?? "unknown"
    print("💬 [ConversationIdentity] participants=\(participants) from=\(fromHeader.prefix(40))")
    #endif

    return ConversationIdentity(key: key, keyHash: hash, type: type, participants: participants)
}

/// Legacy function for backward compatibility
func makeConversationIdentity(from headers: [MessageHeader],
                              myAliases: Set<String>) -> ConversationIdentity {
    return makeConversationIdentity(from: headers, gmThreadId: "", myAliases: myAliases)
}