import Foundation

/// Which of a person's addresses a reply goes to, in a conversation that
/// counts several of them as one participant (`ContactLinkedAddresses`).
///
/// A conversation has one participant row for a person, made from the address
/// of the message that opened it. They may have written from another of their
/// addresses since, and a reply addressed from the rows would go to the one
/// they have stopped using. So a linked participant is answered at the
/// addresses the message being replied to carries.
///
/// The rows answer for a message only while its people are theirs, which is
/// true of every message a conversation was given by its participant hash.
/// It stops being true when a card stops linking two addresses: the chat that
/// was merged keeps the other address's messages, and its rows name only one
/// of the two people. `rowsCanAnswer` is the test for that, and
/// `ReplyMetadataBuilder` then answers the people on the message.
enum ReplyLinkedAddressPolicy {
    /// Whether a reply addressed from the conversation's rows keeps two
    /// promises to the message being replied to: it reaches nobody who was
    /// not on that message, and it reaches the person who wrote it.
    ///
    /// Both hold for a message the conversation was given by its hash. They
    /// fail in a chat that was merged while a card linked two addresses and
    /// has since been unlinked: the row is one person's, the message
    /// another's, and a reply from the rows sends the first person an answer
    /// to the second's mail, quoted text and all.
    ///
    /// It is not a test of equality. Rows that leave out someone the message
    /// names still keep both promises (unless that someone wrote it), and the
    /// reply then goes to the rows, as it always has: a reply adds nobody the
    /// conversation does not hold.
    ///
    /// - Parameters:
    ///   - conversationRecipients: The conversation's participant rows, the
    ///     user's own addresses already removed.
    ///   - messageParticipants: Every address on the message being replied
    ///     to, the user's own already removed. The caller asks only where the
    ///     message's own rows are known to name everyone on it.
    ///   - messageAuthor: The address the message was sent from. One of the
    ///     user's own, or none, asks nothing of the rows.
    ///   - userAddresses: The user's normalized addresses.
    static func rowsCanAnswer(
        conversationRecipients: [String],
        messageParticipants: [String],
        messageAuthor: String?,
        contactLinks: ContactLinkedAddresses,
        userAddresses: Set<String>
    ) -> Bool {
        func person(_ normalizedAddress: String) -> String {
            contactLinks.canonicalAddress(for: normalizedAddress, excluding: userAddresses)
        }
        func people(_ addresses: [String]) -> Set<String> {
            Set(addresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty }.map(person))
        }

        let rows = people(conversationRecipients)
        guard rows.isSubset(of: people(messageParticipants)) else { return false }

        let author = EmailNormalizer.normalize(messageAuthor ?? "")
        guard !author.isEmpty, !userAddresses.contains(author) else { return true }
        return rows.contains(person(author))
    }

    /// Whether a reply's recipients are the people the conversation's rows
    /// name, no one more and no one less.
    ///
    /// It is asked of what a reply was addressed to, whichever rule
    /// addressed it, so the composer can name the recipients where they are
    /// not the chat's own people (`ReplyAddressing.differsFromConversationPeople`).
    /// People, not addresses: a linked participant answered at another of
    /// their addresses is still that participant.
    ///
    /// - Parameters:
    ///   - recipients: The reply's recipients, the user's own addresses
    ///     already removed.
    ///   - conversationRecipients: The conversation's participant rows, the
    ///     user's own addresses already removed.
    ///   - userAddresses: The user's normalized addresses.
    static func recipientsAreConversationPeople(
        recipients: [String],
        conversationRecipients: [String],
        contactLinks: ContactLinkedAddresses,
        userAddresses: Set<String>
    ) -> Bool {
        func people(_ addresses: [String]) -> Set<String> {
            Set(addresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty }.map {
                contactLinks.canonicalAddress(for: $0, excluding: userAddresses)
            })
        }
        return people(recipients) == people(conversationRecipients)
    }

    /// - Parameters:
    ///   - conversationRecipients: The conversation's participant rows, the
    ///     user's own addresses already removed.
    ///   - targetRecipients: The addresses of the message being replied to,
    ///     the user's own already removed.
    ///   - userAddresses: The user's normalized addresses.
    /// - Returns: `conversationRecipients`, with each linked participant
    ///   replaced by those of their addresses that `targetRecipients` holds.
    ///   A participant the target does not name keeps the row's address, and
    ///   so does everyone nothing links: an address is only ever exchanged
    ///   for one the target message itself carried, never for one a contact
    ///   card merely lists. A conversation with no linked participant gets its
    ///   rows back untouched.
    static func recipients(
        conversationRecipients: [String],
        targetRecipients: [String],
        contactLinks: ContactLinkedAddresses,
        userAddresses: Set<String>
    ) -> [String] {
        guard !targetRecipients.isEmpty,
              conversationRecipients.contains(where: {
                  contactLinks.isLinked(EmailNormalizer.normalize($0))
              }) else {
            return conversationRecipients
        }

        func person(_ address: String) -> String {
            contactLinks.canonicalAddress(
                for: EmailNormalizer.normalize(address),
                excluding: userAddresses
            )
        }

        var seen = Set<String>()
        var recipients: [String] = []
        func append(_ address: String) {
            let normalized = EmailNormalizer.normalize(address)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            recipients.append(address)
        }

        for recipient in conversationRecipients {
            guard contactLinks.isLinked(EmailNormalizer.normalize(recipient)) else {
                append(recipient)
                continue
            }
            let recipientPerson = person(recipient)
            let addressesInUse = targetRecipients.filter { person($0) == recipientPerson }
            if addressesInUse.isEmpty {
                append(recipient)
            } else {
                addressesInUse.forEach(append)
            }
        }
        return recipients
    }
}
