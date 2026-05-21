import XCTest
import Contacts
@testable import esc_chatmail

final class ContactsSelfAliasProviderTests: XCTestCase {
    func testAliasesUsesNormalizedGmailEnumerationFallback() async {
        let selfContact = makeContact(emails: [
            "first.last@gmail.com",
            "me@icloud.com"
        ])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [],
            enumeratedContacts: [selfContact]
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .authorized }
        )

        let aliases = await provider.aliases(knownEmails: ["firstlast@gmail.com"])

        XCTAssertEqual(aliases, [
            "firstlast@gmail.com",
            "me@icloud.com"
        ])
        XCTAssertEqual(contactStore.enumerateContactsCallCount, 1)
    }

    func testAliasesDoesNotEnumerateContactsForNonGmailPredicateMiss() async {
        let selfContact = makeContact(emails: [
            "me@example.com",
            "me@icloud.com"
        ])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [],
            enumeratedContacts: [selfContact]
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .authorized }
        )

        let aliases = await provider.aliases(knownEmails: ["me@example.com"])

        XCTAssertEqual(aliases, [])
        XCTAssertEqual(contactStore.enumerateContactsCallCount, 0)
    }

    private func makeContact(emails: [String]) -> CNContact {
        let contact = CNMutableContact()
        contact.emailAddresses = emails.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }
        return contact.copy() as! CNContact
    }
}

private final class StubSelfAliasContactStore: SelfAliasContactStore, @unchecked Sendable {
    private let lock = NSLock()
    private let unifiedContacts: [CNContact]
    private let enumeratedContacts: [CNContact]
    private var _enumerateContactsCallCount = 0

    init(unifiedContacts: [CNContact], enumeratedContacts: [CNContact]) {
        self.unifiedContacts = unifiedContacts
        self.enumeratedContacts = enumeratedContacts
    }

    var enumerateContactsCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _enumerateContactsCallCount
    }

    func unifiedContacts(
        matching predicate: NSPredicate,
        keysToFetch: [CNKeyDescriptor]
    ) throws -> [CNContact] {
        unifiedContacts
    }

    func enumerateContacts(
        with fetchRequest: CNContactFetchRequest,
        usingBlock block: @escaping (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void
    ) throws {
        lock.lock()
        _enumerateContactsCallCount += 1
        lock.unlock()

        for contact in enumeratedContacts {
            var stop = ObjCBool(false)
            block(contact, &stop)
            if stop.boolValue {
                break
            }
        }
    }
}
