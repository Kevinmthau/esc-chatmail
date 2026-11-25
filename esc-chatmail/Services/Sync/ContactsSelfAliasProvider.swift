import Foundation
import Contacts

protocol SelfAliasProviding: Sendable {
    func aliases(knownEmails: [String]) async -> Set<String>
}

protocol SelfAliasContactStore: Sendable {
    func unifiedContacts(
        matching predicate: NSPredicate,
        keysToFetch: [CNKeyDescriptor]
    ) throws -> [CNContact]

    func enumerateContacts(
        with fetchRequest: CNContactFetchRequest,
        usingBlock block: @escaping (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void
    ) throws

#if os(macOS)
    func unifiedMeContact(withKeysToFetch keys: [CNKeyDescriptor]) throws -> CNContact
#endif
}

private final class DefaultSelfAliasContactStore: SelfAliasContactStore, @unchecked Sendable {
    private let contactStore = CNContactStore()

    func unifiedContacts(
        matching predicate: NSPredicate,
        keysToFetch: [CNKeyDescriptor]
    ) throws -> [CNContact] {
        try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
    }

    func enumerateContacts(
        with fetchRequest: CNContactFetchRequest,
        usingBlock block: @escaping (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void
    ) throws {
        try contactStore.enumerateContacts(with: fetchRequest, usingBlock: block)
    }

#if os(macOS)
    /// The Mac's "me" card (`unifiedMeContactWithKeys(toFetch:)`, which iOS lacks). This block
    /// was the repo's only `#if os(macOS)` code before the Mac port and had never compiled: it
    /// called `unifiedMeContact(withKeysToFetch:)`, which `CNContactStore` does not have.
    func unifiedMeContact(withKeysToFetch keys: [CNKeyDescriptor]) throws -> CNContact {
        try contactStore.unifiedMeContactWithKeys(toFetch: keys)
    }
#endif
}

actor ContactsSelfAliasProvider: SelfAliasProviding {
    static let shared = ContactsSelfAliasProvider()

    private let contactStore: any SelfAliasContactStore
    private let authorizationStatusProvider: @Sendable () -> CNAuthorizationStatus

    init(
        contactStore: any SelfAliasContactStore = DefaultSelfAliasContactStore(),
        authorizationStatusProvider: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        }
    ) {
        self.contactStore = contactStore
        self.authorizationStatusProvider = authorizationStatusProvider
    }

    func aliases(knownEmails: [String]) async -> Set<String> {
        guard Self.canReadContacts(status: authorizationStatusProvider()) else {
            return []
        }

        let searchEmails = Self.searchEmails(from: knownEmails)
        guard !searchEmails.isEmpty else {
            return []
        }

        let keysToFetch = [CNContactEmailAddressesKey as CNKeyDescriptor]
        let knownAddresses = Set(
            searchEmails
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
        var aliases = Set<String>()

        #if os(macOS)
        // The Mac's "me" card is the user's own word for who they are, so it
        // counts whatever else it lists.
        if let contact = try? contactStore.unifiedMeContact(withKeysToFetch: keysToFetch) {
            aliases.formUnion(Self.normalizedEmails(from: contact))
        }
        #endif

        // The cards that list one of the user's addresses as stored. Only
        // their addresses beyond the known ones need a decision, and only a
        // walk of the whole address book can make it.
        var matchedCards: [Set<String>] = []
        for email in searchEmails {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            guard let contacts = try? contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: keysToFetch
            ) else {
                continue
            }
            matchedCards.append(contentsOf: contacts.map(Self.normalizedEmails(from:)))
        }

        let matchedAddresses = matchedCards.reduce(into: Set<String>()) { $0.formUnion($1) }
        let gmailTargets = Set(
            searchEmails
                .filter(EmailNormalizer.isGmailAddress)
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )
        let hasUnresolvedGmailTarget = !gmailTargets.subtracting(matchedAddresses).isEmpty
        let listsOtherAddresses = matchedCards.contains { !$0.subtracting(knownAddresses).isEmpty }
        guard hasUnresolvedGmailTarget || listsOtherAddresses else {
            // Every card found lists the user's own addresses and nothing
            // else: nothing to decide, and no walk.
            return aliases.union(matchedAddresses)
        }

        // A card that lists the user's address beside another counts only
        // when no card of someone else's lists that other address
        // (`SelfContactCards`), which needs every card. A walk that fails
        // admits no such card: someone else's mail drawn as the user's own,
        // and their chats merged into note-to-self, is worse than an alias
        // missed for one run.
        guard let allCards = allContactAddressLists(keysToFetch: keysToFetch) else {
            return aliases
        }
        aliases.formUnion(
            SelfContactCards.selfAddresses(
                contactAddressLists: allCards,
                knownAddresses: knownAddresses
            )
        )
        return aliases
    }

    /// The addresses of every contact card, or nil when the walk failed.
    private func allContactAddressLists(keysToFetch: [CNKeyDescriptor]) -> [[String]]? {
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var cards: [[String]] = []

        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let addresses = contact.emailAddresses.map { String($0.value) }
                guard !addresses.isEmpty else { return }
                cards.append(addresses)
            }
        } catch {
            Log.error("Contact enumeration failed for self aliases", category: .general, error: error)
            return nil
        }

        return cards
    }

    private static func canReadContacts(status: CNAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }

        if status.isLimitedAccess {
            return true
        }

        return false
    }

    private static func searchEmails(from knownEmails: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for email in knownEmails {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = EmailNormalizer.normalize(trimmed)

            for candidate in [trimmed, normalized] where !candidate.isEmpty {
                let comparable = candidate.lowercased()
                guard seen.insert(comparable).inserted else { continue }
                result.append(candidate)
            }
        }

        return result
    }

    private static func normalizedEmails(from contact: CNContact) -> Set<String> {
        Set(
            contact.emailAddresses
                .map { EmailNormalizer.normalize(String($0.value)) }
                .filter { !$0.isEmpty }
        )
    }
}
