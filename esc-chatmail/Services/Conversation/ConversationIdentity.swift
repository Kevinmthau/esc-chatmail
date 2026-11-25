import Foundation
import CryptoKit

/// Calculates participant hash from sorted participant emails.
/// CANONICAL IMPLEMENTATION - use this everywhere, do not duplicate.
/// - Parameter participants: Array of normalized email addresses (user's aliases should already be excluded),
///   one per person: `makeParticipantSetIdentity` folds the addresses a contact card links before it calls this.
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
    let key: String              // "p|alice@example.com" (one-to-one) OR "p|alice@x|bob@y" (group) OR "l|<list-id>" (mailing list)
    let keyHash: String          // SHA256 hex of key (unique per conversation instance)
    let participantHash: String  // SHA256 hex of participant key (same for all convos with same participants), or of the list key
    let type: ConversationType
    let participants: [String]   // normalized emails, excluding "me"
    let participantDisplayNames: [String: String]  // normalized email -> display name
    let listId: String?          // normalized List-Id when this is a mailing-list identity
    let listTitle: String?       // List-Id display phrase, consumed once at conversation creation
}

/// The participant-set core of a conversation identity: the sorted, self-excluded
/// participant list and its canonical hash, without the per-instance keyHash/epoch parts.
/// When `listId` is non-nil the identity is a mailing-list identity: `participantHash`
/// is derived from the List-Id ("l|" namespace) and `participants` only seeds
/// display/reply rows.
struct ParticipantSetIdentity {
    let participants: [String]   // sorted, normalized, aliases removed (or self-fallback), one address per person (`ContactLinkedAddresses`)
    let participantHash: String
    let type: ConversationType
    let listId: String?
}

/// CANONICAL participant-set derivation shared by the sync router (via
/// `makeConversationIdentity`), the compose/optimistic-send path, and the
/// participant-set split migration. All paths must agree on this hash or the
/// same set of people forks into duplicate chats.
///
/// A participant is a person, not an address: addresses one contact card links
/// (`ContactLinkedAddresses`) hash as one, so mail from someone's second
/// address joins the chat their first one has. With nothing linked the hash is
/// the plain address-set hash, which is what the web app computes.
///
/// - Parameter normalizedEmails: From+To+Cc addresses already normalized via
///   `normalizedEmail(_:)`, with BCC and Hide-My-Email entries excluded.
/// - Parameter myAliases: normalized self addresses to exclude from the set.
/// - Parameter contactLinks: The linked addresses to hash with. Every caller
///   must hash with the map `ContactLinkedAddressStore` has adopted, which the
///   default reads; a pass that hashes many rows reads it once and passes it,
///   so one pass never mixes two maps.
func makeParticipantSetIdentity(
    normalizedEmails: Set<String>,
    myAliases: Set<String>,
    contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
) -> ParticipantSetIdentity {
    let parts = normalizedEmails.filter { !myAliases.contains($0) }

    let participants: [String]
    let hashKeys: [String]
    if parts.isEmpty {
        // Self-conversation: use deterministic alias selection (sorted order)
        if let firstAlias = myAliases.sorted().first {
            participants = [firstAlias]
        } else if let firstEmail = normalizedEmails.sorted().first {
            participants = [firstEmail]
        } else {
            participants = ["unknown@email.com"]
        }
        hashKeys = participants
    } else {
        (participants, hashKeys) = contactLinks.unifiedParticipants(parts, excluding: myAliases)
    }

    return ParticipantSetIdentity(
        participants: participants,
        participantHash: calculateParticipantHash(from: hashKeys),
        type: hashKeys.count <= 1 ? .oneToOne : .group,
        listId: nil
    )
}

/// CANONICAL mailing-list identity derivation shared by the sync router (via
/// `makeConversationIdentity`) and `Message.strictParticipantSetIdentity`. The
/// conversation is keyed by the normalized List-Id alone; the message's
/// participant set only seeds display/reply rows. Both paths must agree on the
/// hash or the same list forks into duplicate chats.
func makeListSetIdentity(
    normalizedListId: String,
    normalizedEmails: Set<String>,
    myAliases: Set<String>,
    contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
) -> ParticipantSetIdentity {
    let setIdentity = makeParticipantSetIdentity(normalizedEmails: normalizedEmails,
                                                 myAliases: myAliases,
                                                 contactLinks: contactLinks)
    return ParticipantSetIdentity(
        participants: setIdentity.participants,
        participantHash: calculateListConversationHash(fromNormalizedListId: normalizedListId),
        type: .list,
        listId: normalizedListId
    )
}

/// Compose-side participant-set identity for a raw recipient list.
/// Returns nil when no recipient yields a usable normalized address.
func makeRecipientParticipantSetIdentity(
    recipients: [String],
    myAliases: Set<String>,
    contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
) -> ParticipantSetIdentity? {
    let normalized = Set(recipients.map(normalizedEmail).filter { !$0.isEmpty })
    guard !normalized.isEmpty else { return nil }
    return makeParticipantSetIdentity(normalizedEmails: normalized,
                                      myAliases: myAliases,
                                      contactLinks: contactLinks)
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
/// Routing prefers an active conversation with the same participantHash.
/// INBOX arrivals, own messages, and SENT mail can reuse and reactivate the most
/// recent archived match. Other arrivals can create a new epoch when only archived
/// matches exist; rollup immediately archives it if it has no inbox mail and no
/// outgoing latest message. A newly created epoch has a distinct keyHash.
/// Existing-message List-Id repair instead reuses archived matches without reactivation.
///
/// Key format: "p|<sorted-participants>|<uuid>" where participants excludes the current user
func makeConversationIdentity(
    from headers: [MessageHeader],
    myAliases: Set<String>,
    contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
) -> ConversationIdentity {
    func mailboxes(_ name: String) -> [EmailAddress] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { EmailAddressListParser.mailboxes(from: $0.value) }
    }

    // BCC is intentionally excluded for both identity and display.
    let rawListId = headers.first { $0.name.caseInsensitiveCompare("List-Id") == .orderedSame }?.value
    return makeConversationIdentity(
        participants: mailboxes("From") + mailboxes("To") + mailboxes("Cc"),
        rawListId: rawListId,
        myAliases: myAliases,
        contactLinks: contactLinks
    )
}

/// The identity of a message whose From, To and Cc mailboxes are already
/// parsed (`EmailAddressListParser.mailboxes(from:)`): the one place the
/// participant set is built from a message's addresses.
///
/// It takes the parsed addresses and never a header rebuilt from them. The
/// router used to join each parsed To/Cc as `name <email>` and split the
/// result again on every comma, and the name there is already decoded and
/// unquoted: a name `"bob@old.example, Bob"` added bob@old.example to the
/// chat, an encoded name that decoded to `<boss@corp.example>` replaced the
/// recipient's address with that one, and a nameless address the bare-address
/// pattern rejects (`<étudiant@x.fr>`, `<ops@intranet>`) was dropped. The
/// message's rows and the web app read the parsed values, so the chat was
/// keyed on people its messages did not name.
func makeConversationIdentity(
    participants: [EmailAddress],
    rawListId: String?,
    myAliases: Set<String>,
    contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
) -> ConversationIdentity {
    var displayNames: [String: String] = [:]
    var allEmails = Set<String>()

    for participant in participants {
        let normalized = normalizedEmail(participant.email)
        guard !normalized.isEmpty else { continue }

        // Extract display name if it's better than what we have
        if let displayName = participant.displayName {
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

    // Mailing-list mail groups by List-Id, not by participant set: list
    // participants vary per message (rotating From, changing Cc), which would
    // shatter one list into many chats. A malformed List-Id parses to nil and
    // falls back to participant grouping.
    if let parsed = ParsedListId.parse(rawListId) {
        let listIdentity = makeListSetIdentity(normalizedListId: parsed.id,
                                               normalizedEmails: allEmails,
                                               myAliases: myAliases,
                                               contactLinks: contactLinks)
        return makeConversationIdentity(from: listIdentity,
                                        displayNames: displayNames,
                                        listTitle: parsed.title)
    }

    let setIdentity = makeParticipantSetIdentity(normalizedEmails: allEmails,
                                                 myAliases: myAliases,
                                                 contactLinks: contactLinks)

    #if DEBUG
    Log.debug("[ConversationIdentity] participants=\(setIdentity.participants.count)", category: .conversation)
    #endif

    return makeConversationIdentity(from: setIdentity, displayNames: displayNames)
}

/// Builds a full per-instance ConversationIdentity (fresh keyHash epoch) from a
/// participant-set identity. Used by the header path above and by callers that
/// derive the participant set without headers (the participant-set split migration).
func makeConversationIdentity(from setIdentity: ParticipantSetIdentity,
                              displayNames: [String: String] = [:],
                              listTitle: String? = nil) -> ConversationIdentity {
    let baseKey: String
    if let listId = setIdentity.listId {
        baseKey = "l|\(listId)"
    } else {
        baseKey = "p|\(setIdentity.participants.joined(separator: "|"))"
    }

    // Create unique key for this conversation instance (includes UUID for uniqueness)
    // This allows multiple conversations with the same participants (archived vs active)
    let uniqueKey = "\(baseKey)|\(UUID().uuidString)"
    let keyHash = SHA256.hash(data: Data(uniqueKey.utf8)).map { String(format:"%02x", $0) }.joined()

    return ConversationIdentity(
        key: uniqueKey,
        keyHash: keyHash,
        participantHash: setIdentity.participantHash,
        type: setIdentity.type,
        participants: setIdentity.participants,
        participantDisplayNames: displayNames,
        listId: setIdentity.listId,
        listTitle: setIdentity.listId != nil ? listTitle : nil
    )
}
