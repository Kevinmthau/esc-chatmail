import Foundation
import Contacts

protocol SelfAliasProviding: Sendable {
    func aliases(knownEmails: [String]) async -> Set<String>
}

actor ContactsSelfAliasProvider: SelfAliasProviding {
    static let shared = ContactsSelfAliasProvider()

    private let contactStore: CNContactStore

    init(contactStore: CNContactStore = CNContactStore()) {
        self.contactStore = contactStore
    }

    func aliases(knownEmails: [String]) async -> Set<String> {
        guard Self.canReadContacts else {
            return []
        }

        let searchEmails = Self.searchEmails(from: knownEmails)
        guard !searchEmails.isEmpty else {
            return []
        }

        let keysToFetch = [CNContactEmailAddressesKey as CNKeyDescriptor]
        var aliases = Set<String>()

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

        return aliases
    }

    private static var canReadContacts: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
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
