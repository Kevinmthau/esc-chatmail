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
    func unifiedMeContact(withKeysToFetch keys: [CNKeyDescriptor]) throws -> CNContact {
        try contactStore.unifiedMeContact(withKeysToFetch: keys)
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
        var aliases = Set<String>()
        let gmailTargets = Set(
            searchEmails
                .filter(EmailNormalizer.isGmailAddress)
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )

        #if os(macOS)
        if let contact = try? contactStore.unifiedMeContact(withKeysToFetch: keysToFetch) {
            aliases.formUnion(Self.normalizedEmails(from: contact))
        }
        #endif

        for email in searchEmails {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            guard let contacts = try? contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: keysToFetch
            ) else {
                continue
            }

            for contact in contacts {
                aliases.formUnion(Self.normalizedEmails(from: contact))
            }
        }

        let unresolvedGmailTargets = gmailTargets.subtracting(aliases)
        if !unresolvedGmailTargets.isEmpty {
            aliases.formUnion(
                aliasesByEnumeratingContacts(
                    matchingNormalizedEmails: unresolvedGmailTargets,
                    keysToFetch: keysToFetch
                )
            )
        }

        return aliases
    }

    private func aliasesByEnumeratingContacts(
        matchingNormalizedEmails normalizedEmails: Set<String>,
        keysToFetch: [CNKeyDescriptor]
    ) -> Set<String> {
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var aliases = Set<String>()

        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let contactAliases = Self.normalizedEmails(from: contact)
                guard !contactAliases.isDisjoint(with: normalizedEmails) else { return }
                aliases.formUnion(contactAliases)
            }
        } catch {
            Log.error("Contact enumeration failed for self aliases", category: .general, error: error)
        }

        return aliases
    }

    private static func canReadContacts(status: CNAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }

        if #available(iOS 18.0, *), status == .limited {
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
