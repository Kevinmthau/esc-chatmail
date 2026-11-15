import Foundation

/// Which email addresses stand for one person, as the user's Contacts say: two
/// addresses are linked when one contact card lists both.
///
/// Conversation identity reads this so that a person who writes from two of
/// their addresses is one participant and one chat
/// (`makeParticipantSetIdentity`). It is a value: the map in force is the one
/// `ContactLinkedAddressStore` has adopted, and every hash of one pass is made
/// from one snapshot of it.
///
/// A link is only ever what a card states. Three rules keep one card from
/// joining two people:
/// - An address on two cards that each list an address the other does not
///   (a family or office address on two people's cards) links nothing. The
///   cards' other addresses are still linked among themselves.
/// - A card whose addresses are all on one other card is that card again (the
///   same person kept in two accounts) and adds nothing of its own.
/// - Links are not chained: nothing is linked through a third address.
struct ContactLinkedAddresses: Equatable, Sendable {
    /// No address is linked to another. What identity was before Contacts were
    /// read, and what it stays without Contacts access.
    static let none = ContactLinkedAddresses(groupsByAddress: [:])

    /// Normalized address → the addresses its card links it to, itself among
    /// them, sorted. Only linked addresses are keys.
    private let groupsByAddress: [String: [String]]

    private init(groupsByAddress: [String: [String]]) {
        self.groupsByAddress = groupsByAddress
    }

    /// - Parameter contactAddressLists: The addresses of each contact card, as
    ///   stored. A card with fewer than two distinct normalized addresses
    ///   links nothing and may be left out.
    init(contactAddressLists: some Sequence<[String]>) {
        // Each card as its set of normalized addresses, identical cards once.
        var cards: [Set<String>] = []
        var seenCards = Set<Set<String>>()
        for addresses in contactAddressLists {
            let card = Set(addresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
            guard card.count > 1, seenCards.insert(card).inserted else { continue }
            cards.append(card)
        }

        var cardIndexesByAddress: [String: [Int]] = [:]
        for (index, card) in cards.enumerated() {
            for address in card {
                cardIndexesByAddress[address, default: []].append(index)
            }
        }

        // A card that another card contains is the same person again. A card
        // that contains it holds every one of its addresses, so it is among
        // the cards sharing any one of them. Identical cards were dropped
        // above, so "contains" is strict here and no two cards drop each other.
        let standsAlone: [Bool] = cards.enumerated().map { index, card in
            guard let anyAddress = card.first else { return false }
            return !(cardIndexesByAddress[anyAddress] ?? []).contains { other in
                other != index && card.isSubset(of: cards[other])
            }
        }

        var cardCountByAddress: [String: Int] = [:]
        for (index, card) in cards.enumerated() where standsAlone[index] {
            for address in card {
                cardCountByAddress[address, default: 0] += 1
            }
        }

        var groupsByAddress: [String: [String]] = [:]
        for (index, card) in cards.enumerated() where standsAlone[index] {
            let group = card.filter { cardCountByAddress[$0] == 1 }.sorted()
            guard group.count > 1 else { continue }
            for address in group {
                groupsByAddress[address] = group
            }
        }
        self.init(groupsByAddress: groupsByAddress)
    }

    var isEmpty: Bool {
        groupsByAddress.isEmpty
    }

    /// The linked groups, each sorted, in the order of their first addresses.
    /// Building a map from its own groups gives the same map back.
    var groups: [[String]] {
        Set(groupsByAddress.values).sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Whether a card links this address to another.
    func isLinked(_ normalizedAddress: String) -> Bool {
        groupsByAddress[normalizedAddress] != nil
    }

    /// The address that stands for `normalizedAddress`'s person in a
    /// participant hash: the first of its linked addresses that is not one of
    /// the user's own, or the address itself when nothing links it.
    ///
    /// The user's addresses are left out here, not when the map is built,
    /// because they are known per account and the map is not: a card that
    /// lists one of them beside its owner's must not make the user's own
    /// address stand for that person, nor that person's for the user.
    func canonicalAddress(for normalizedAddress: String, excluding myAliases: Set<String>) -> String {
        guard !myAliases.contains(normalizedAddress),
              let group = groupsByAddress[normalizedAddress] else {
            return normalizedAddress
        }
        return group.first { !myAliases.contains($0) } ?? normalizedAddress
    }

    /// One conversation's participants with linked addresses folded together.
    ///
    /// - Parameter addresses: Normalized addresses, the user's own already
    ///   removed.
    /// - Returns: `hashKeys`, one canonical address per person, sorted: what
    ///   the participant hash is made from and what the conversation's type
    ///   counts. `addresses`, one address per person, sorted: the first of
    ///   that person's addresses present, which is what a new conversation's
    ///   participant rows are made from. A row must be an address the message
    ///   carried, never one the card merely lists, because a reply reads the
    ///   rows.
    func unifiedParticipants(
        _ addresses: some Sequence<String>,
        excluding myAliases: Set<String>
    ) -> (addresses: [String], hashKeys: [String]) {
        var seenKeys = Set<String>()
        var kept: [String] = []
        for address in addresses.sorted() {
            let key = canonicalAddress(for: address, excluding: myAliases)
            guard seenKeys.insert(key).inserted else { continue }
            kept.append(address)
        }
        return (kept, seenKeys.sorted())
    }

    /// Every address whose linked group is not the same in `other`: the
    /// addresses whose conversations can hash differently under the two maps.
    /// A group that changed has changed for each of its members, so two
    /// conversations that come to share a hash both name one of these.
    func addressesLinkedDifferently(from other: ContactLinkedAddresses) -> Set<String> {
        var changed = Set<String>()
        for (address, group) in groupsByAddress where other.groupsByAddress[address] != group {
            changed.insert(address)
        }
        for (address, group) in other.groupsByAddress where groupsByAddress[address] != group {
            changed.insert(address)
        }
        return changed
    }

    // MARK: - Stored form

    /// The map as a string to keep in defaults: its groups as JSON. Nil when
    /// nothing is linked, which is stored as no value at all.
    var encoded: String? {
        guard !isEmpty,
              let data = try? JSONEncoder().encode(groups) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The map `encoded` wrote. A missing or unreadable value is `none`: the
    /// pass that compares the applied map with the adopted one then sees
    /// every link as new and applies it again, which changes nothing that is
    /// already right.
    init(encoded: String?) {
        guard let encoded,
              let groups = try? JSONDecoder().decode([[String]].self, from: Data(encoded.utf8)) else {
            self = .none
            return
        }
        self.init(contactAddressLists: groups)
    }
}
