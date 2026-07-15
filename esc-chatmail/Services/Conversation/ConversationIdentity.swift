import Foundation
import CryptoKit

/// Calculates participant hash from sorted participant emails.
/// CANONICAL IMPLEMENTATION - use this everywhere, do not duplicate.
/// - Parameter participants: Array of normalized email addresses (user's aliases should already be excluded)
/// - Returns: SHA256 hex string of the participant key
func calculateParticipantHash(from participants: [String]) -> String {
    let participantKey = "p|\(participants.sorted().joined(separator: "|"))"
    return SHA256.hash(data: Data(participantKey.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

/// Calculates the conversation hash for a mailing-list identity.
/// CANONICAL IMPLEMENTATION - use this everywhere, do not duplicate.
/// The "l|" namespace keeps list hashes disjoint from every participant-set
/// hash ("p|"), so both kinds share the Conversation.participantHash attribute
/// without collisions.
/// - Parameter listId: Normalized List-Id (see `ParsedListId.parse`)
/// - Returns: SHA256 hex string of the list key
func calculateListConversationHash(fromNormalizedListId listId: String) -> String {
    let listKey = "l|\(listId)"
    return SHA256.hash(data: Data(listKey.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

struct ConversationIdentity {
    let key: String              // "p|alice@example.com" (one-to-one) OR "p|alice@x|bob@y" (group)
    let keyHash: String          // SHA256 hex of key (unique per conversation instance)
    let participantHash: String  // SHA256 hex of participant key (same for all convos with same participants)
    let type: ConversationType
    let participants: [String]   // normalized emails, excluding "me"
    let participantDisplayNames: [String: String]  // normalized email -> display name
}

/// The participant-set core of a conversation identity: the sorted, self-excluded
/// participant list and its canonical hash, without the per-instance keyHash/epoch parts.
struct ParticipantSetIdentity {
    let participants: [String]   // sorted, normalized, aliases removed (or self-fallback)
    let participantHash: String
    let type: ConversationType
}

/// CANONICAL participant-set derivation shared by the sync router (via
/// `makeConversationIdentity`), the compose/optimistic-send path, and the
/// participant-set split migration. All paths must agree on this hash or the
/// same set of people forks into duplicate chats.
///
/// - Parameter normalizedEmails: From+To+Cc addresses already normalized via
///   `normalizedEmail(_:)`, with BCC and Hide-My-Email entries excluded.
/// - Parameter myAliases: normalized self addresses to exclude from the set.
func makeParticipantSetIdentity(normalizedEmails: Set<String>,
                                myAliases: Set<String>) -> ParticipantSetIdentity {
    let parts = normalizedEmails.filter { !myAliases.contains($0) }

    let participants: [String]
    if parts.isEmpty {
        // Self-conversation: use deterministic alias selection (sorted order)
        if let firstAlias = myAliases.sorted().first {
            participants = [firstAlias]
        } else if let firstEmail = normalizedEmails.sorted().first {
            participants = [firstEmail]
        } else {
            participants = ["unknown@email.com"]
        }
    } else {
        participants = parts.sorted()
    }

    return ParticipantSetIdentity(
        participants: participants,
        participantHash: calculateParticipantHash(from: participants),
        type: participants.count <= 1 ? .oneToOne : .group
    )
}

/// Compose-side participant-set identity for a raw recipient list.
/// Returns nil when no recipient yields a usable normalized address.
func makeRecipientParticipantSetIdentity(recipients: [String],
                                         myAliases: Set<String>) -> ParticipantSetIdentity? {
    let normalized = Set(recipients.map(normalizedEmail).filter { !$0.isEmpty })
    guard !normalized.isEmpty else { return nil }
    return makeParticipantSetIdentity(normalizedEmails: normalized, myAliases: myAliases)
}

/// Canonical email normalization for identity hashing. Delegates to
/// `EmailNormalizer.normalize` so the app has exactly one normalizer — a
/// second implementation drifting here would fork participant hashes.
func normalizedEmail(_ raw: String) -> String {
    EmailNormalizer.normalize(raw)
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
                              myAliases: Set<String>) -> ConversationIdentity {
    // Extract all participant emails from From, To, Cc headers
    // BCC is explicitly excluded for both identity and display
    func extractEmailsWithDisplayNames() -> (Set<String>, [String: String]) {
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

            // Extract display name if it's better than what we have
            if let displayName = EmailNormalizer.extractDisplayName(from: headerValue) {
                // "Hide My Email" is an Apple relay placeholder, not a real participant.
                if EmailNormalizer.isHideMyEmailDisplayName(displayName) {
                    continue
                }
                if EmailNormalizer.isBetterDisplayName(displayName, than: displayNames[normalized], forEmail: normalized) {
                    displayNames[normalized] = displayName
                }
            }

            allEmails.insert(normalized)
        }

        return (allEmails, displayNames)
    }

    let (allEmails, displayNames) = extractEmailsWithDisplayNames()
    let setIdentity = makeParticipantSetIdentity(normalizedEmails: allEmails, myAliases: myAliases)

    #if DEBUG
    let fromHeader = headers.first(where: { $0.name.caseInsensitiveCompare("From") == .orderedSame })?.value ?? "unknown"
    Log.debug("[ConversationIdentity] participants=\(setIdentity.participants) from=\(fromHeader.prefix(40))", category: .conversation)
    #endif

    return makeConversationIdentity(from: setIdentity, displayNames: displayNames)
}

/// Builds a full per-instance ConversationIdentity (fresh keyHash epoch) from a
/// participant-set identity. Used by the header path above and by callers that
/// derive the participant set without headers (the participant-set split migration).
func makeConversationIdentity(from setIdentity: ParticipantSetIdentity,
                              displayNames: [String: String] = [:]) -> ConversationIdentity {
    let participantKey = "p|\(setIdentity.participants.joined(separator: "|"))"

    // Create unique key for this conversation instance (includes UUID for uniqueness)
    // This allows multiple conversations with the same participants (archived vs active)
    let uniqueKey = "\(participantKey)|\(UUID().uuidString)"
    let keyHash = SHA256.hash(data: Data(uniqueKey.utf8)).map { String(format:"%02x", $0) }.joined()

    return ConversationIdentity(
        key: uniqueKey,
        keyHash: keyHash,
        participantHash: setIdentity.participantHash,
        type: setIdentity.type,
        participants: setIdentity.participants,
        participantDisplayNames: displayNames
    )
}
