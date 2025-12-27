import Foundation
import CryptoKit

struct ConversationIdentity {
    let key: String              // "p|alice@example.com" (one-to-one) OR "p|alice@x|bob@y" (group)
    let keyHash: String          // SHA256 hex of key (unique per conversation instance)
    let participantHash: String  // SHA256 hex of participant key (same for all convos with same participants)
    let type: ConversationType
    let participants: [String]   // normalized emails, excluding "me"
    let participantDisplayNames: [String: String]  // normalized email -> display name
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
///
/// Key concepts:
/// - participantHash: Identifies the SET of participants (same for all convos with same people)
/// - keyHash: Unique identifier for THIS conversation instance (includes UUID for uniqueness)
///
/// This allows:
/// - Multiple conversation "epochs" with the same participants
/// - When a conversation is archived and a new email arrives, a NEW conversation is created
/// - The new conversation has the same participantHash but different keyHash
///
/// Key format: "p|<sorted-participants>|<uuid>" where participants excludes the current user
func makeConversationIdentity(from headers: [MessageHeader],
                              gmThreadId: String,
                              myAliases: Set<String>) -> ConversationIdentity {
    // Extract all participants from From, To, Cc headers
    // BCC is explicitly excluded for both identity and display
    func extractParticipantsWithDisplayNames() -> ([String], [String: String]) {
        func values(_ h: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(h) == .orderedSame }
                .flatMap { $0.value.split(separator: ",").map(String.init) }
        }

        let raw = values("From") + values("To") + values("Cc")
        // Note: BCC is intentionally excluded

        var displayNames: [String: String] = [:]
        var allEmails = Set<String>()

        for headerValue in raw {
            guard let email = EmailNormalizer.extractEmail(from: headerValue) else { continue }
            let normalized = normalizedEmail(email)
            guard !normalized.isEmpty else { continue }

            allEmails.insert(normalized)

            // Extract display name if we don't already have one for this email
            if displayNames[normalized] == nil,
               let displayName = EmailNormalizer.extractDisplayName(from: headerValue),
               !displayName.isEmpty {
                displayNames[normalized] = displayName
            }
        }

        // Remove current user's aliases from participants
        let parts = allEmails.filter { !myAliases.contains($0) }

        if parts.isEmpty {
            // Self-conversation: use deterministic alias selection (sorted order)
            if let firstAlias = myAliases.sorted().first {
                return ([firstAlias], displayNames)
            } else if let firstEmail = allEmails.sorted().first {
                return ([firstEmail], displayNames)
            } else {
                return (["unknown@email.com"], displayNames)
            }
        } else {
            return (parts.sorted(), displayNames)
        }
    }

    let (participants, displayNames) = extractParticipantsWithDisplayNames()
    let type: ConversationType = participants.count <= 1 ? .oneToOne : .group

    // Create participant-based key (used for looking up conversations by participants)
    let participantKey = "p|\(participants.joined(separator: "|"))"
    let participantHash = SHA256.hash(data: Data(participantKey.utf8)).map { String(format:"%02x", $0) }.joined()

    // Create unique key for this conversation instance (includes UUID for uniqueness)
    // This allows multiple conversations with the same participants (archived vs active)
    let uniqueKey = "\(participantKey)|\(UUID().uuidString)"
    let keyHash = SHA256.hash(data: Data(uniqueKey.utf8)).map { String(format:"%02x", $0) }.joined()

    #if DEBUG
    let fromHeader = headers.first(where: { $0.name.caseInsensitiveCompare("From") == .orderedSame })?.value ?? "unknown"
    print("💬 [ConversationIdentity] participants=\(participants) from=\(fromHeader.prefix(40))")
    #endif

    return ConversationIdentity(
        key: uniqueKey,
        keyHash: keyHash,
        participantHash: participantHash,
        type: type,
        participants: participants,
        participantDisplayNames: displayNames
    )
}

/// Legacy function for backward compatibility
func makeConversationIdentity(from headers: [MessageHeader],
                              myAliases: Set<String>) -> ConversationIdentity {
    return makeConversationIdentity(from: headers, gmThreadId: "", myAliases: myAliases)
}