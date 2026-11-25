import Foundation

/// Which Contacts cards are the user's own, and so which of their addresses
/// count as the user's (adopted by `ContactLinkedAddressStore`, read by `AliasManager`).
///
/// The self set decides `isFromMe`, is removed before every participant hash
/// and is filtered out of reply recipients, so a card that only lists the
/// user's address beside someone else's must not make that person the user.
/// A card that lists one of the user's own addresses counts only when none of
/// its other addresses is on a card that lists none of the user's addresses:
/// - A household card for a shared Gmail account lists the partner's address,
///   which is also on the partner's own card, so it does not count.
/// - A company card that lists colleagues beside the user's send-as address
///   does not count once any of those colleagues has a card of their own.
/// - The user's own card, and a copy of it kept in a second account that lists
///   a known address too, count.
/// A card is counted or left out whole: one foreign address on it makes every
/// address it lists suspect.
///
/// What this cannot tell apart, because it reads addresses and not names: a
/// card that lists the user beside someone who has no card of their own
/// counts, as every such card did before this rule; and any card that names
/// none of the known addresses but lists one of the user's other addresses
/// (a leftover self card in another account, a team card, a partner's card
/// listing the user's iCloud address) reads as someone else's and takes the
/// user's own card out with it.
enum SelfContactCards {
    /// The addresses of the cards that count as the user's own, normalized.
    /// The user's known addresses are included only where such a card lists
    /// them; callers union this with the addresses they already know.
    ///
    /// - Parameters:
    ///   - contactAddressLists: The addresses of every contact card, as stored.
    ///     A card left out is a card that cannot disqualify another, so pass
    ///     the whole address book or nothing.
    ///   - knownAddresses: The account address and its send-as addresses, in
    ///     any form; they are normalized here. Only a card listing one of
    ///     these can count.
    ///   - trustedAddresses: Addresses the user has declared their own in
    ///     some other way (the Mac's "me" card). They never disqualify a card
    ///     and a card listing only them claims nothing, but they do not make a
    ///     card count: a "me" card that lists someone else must not make that
    ///     person's own card the user's.
    static func selfAddresses(
        contactAddressLists: some Sequence<[String]>,
        knownAddresses: some Sequence<String>,
        trustedAddresses: Set<String> = []
    ) -> Set<String> {
        let known = Set(knownAddresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        guard !known.isEmpty else { return [] }
        let trusted = Set(trustedAddresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty })

        let cards: [Set<String>] = contactAddressLists.map { addresses in
            Set(addresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        }

        // Every address that some card naming none of the user's addresses
        // lists: an address someone else's card claims. A card that lists
        // only trusted addresses is the user's and claims nothing.
        var claimedByOthers = Set<String>()
        for card in cards where card.isDisjoint(with: known) && !card.isSubset(of: trusted) {
            claimedByOthers.formUnion(card)
        }

        let ownAddresses = known.union(trusted)
        var result = Set<String>()
        for card in cards where !card.isDisjoint(with: known) {
            guard card.subtracting(ownAddresses).isDisjoint(with: claimedByOthers) else { continue }
            result.formUnion(card)
        }
        return result
    }
}
