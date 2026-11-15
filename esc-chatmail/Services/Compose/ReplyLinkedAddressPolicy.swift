import Foundation

/// Which of a person's addresses a reply goes to, in a conversation that
/// counts several of them as one participant (`ContactLinkedAddresses`).
///
/// A conversation has one participant row for a person, made from the address
/// of the message that opened it. They may have written from another of their
/// addresses since, and a reply addressed from the rows would go to the one
/// they have stopped using. So a linked participant is answered at the
/// addresses the message being replied to carries.
enum ReplyLinkedAddressPolicy {
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
