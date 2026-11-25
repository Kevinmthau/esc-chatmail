#if os(iOS)
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

    // Revert-check: restoring the union of every matched card in
    // `ContactsSelfAliasProvider.aliases(knownEmails:)`, or the
    // `claimedByOthers` guard in `SelfContactCards.selfAddresses`, makes Jane
    // one of the user's addresses: her mail drawn as the user's own and her
    // chat keyed as note-to-self.
    func testAliases_householdCardWhosePartnerHasOwnCard_doesNotAdmitPartner() async {
        let household = makeContact(emails: ["kevin@example.com", "jane@example.com"])
        let jane = makeContact(emails: ["jane@example.com", "jane@work.example"])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [household],
            enumeratedContacts: [household, jane]
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .authorized }
        )

        let aliases = await provider.aliases(knownEmails: ["kevin@example.com"])

        XCTAssertFalse(aliases.contains("jane@example.com"))
        XCTAssertEqual(aliases, [])
    }

    // Revert-check: the `claimedByOthers` guard in
    // `SelfContactCards.selfAddresses` (Jane is admitted with the household
    // card).
    func testAliases_ownCardBesideHouseholdCard_admitsOwnCardOnly() async {
        let own = makeContact(emails: ["kevin@example.com", "kevin@icloud.com"])
        let household = makeContact(emails: ["kevin@example.com", "jane@example.com"])
        let jane = makeContact(emails: ["jane@example.com"])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [own, household],
            enumeratedContacts: [own, household, jane]
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .authorized }
        )

        let aliases = await provider.aliases(knownEmails: ["kevin@example.com"])

        XCTAssertEqual(aliases, ["kevin@example.com", "kevin@icloud.com"])
    }

    // Revert-check: the `nil` return of `allContactAddressLists` on a thrown
    // walk. The stub hands over the household card and then throws, so Jane's
    // own card is never read: taking what the walk read before it failed
    // admits Jane.
    func testAliases_walkFailsPartWay_admitsNoCardListingAnotherAddress() async {
        let household = makeContact(emails: ["kevin@example.com", "jane@example.com"])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [household],
            enumeratedContacts: [household],
            enumerationError: CocoaError(.fileReadUnknown)
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .authorized }
        )

        let aliases = await provider.aliases(knownEmails: ["kevin@example.com"])

        XCTAssertFalse(aliases.contains("jane@example.com"))
        XCTAssertEqual(aliases, [])
        XCTAssertEqual(contactStore.enumerateContactsCallCount, 1)
    }

    // Revert-check: the `!status.isLimitedAccess` guard in
    // `ContactsSelfAliasProvider.aliases(knownEmails:)`. Limited access walks
    // only the cards the user shared, here the household card without
    // Jane's own, so the walk admits Jane.
    func testAliases_limitedAccess_admitsNoCardListingAnotherAddress() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("`.limited` exists from iOS 18")
        }
        let household = makeContact(emails: ["kevin@example.com", "jane@example.com"])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [household],
            enumeratedContacts: [household]
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .limited }
        )

        let aliases = await provider.aliases(knownEmails: ["kevin@example.com"])

        XCTAssertEqual(aliases, [])
        XCTAssertEqual(contactStore.enumerateContactsCallCount, 0)
    }

    /// A card that lists only the user's own addresses needs no decision, so
    /// the address book is not walked.
    func testAliases_cardListingOnlyKnownAddresses_doesNotEnumerate() async {
        let own = makeContact(emails: ["kevin@example.com", "Kevin@Example.com "])
        let contactStore = StubSelfAliasContactStore(
            unifiedContacts: [own],
            enumeratedContacts: [own]
        )
        let provider = ContactsSelfAliasProvider(
            contactStore: contactStore,
            authorizationStatusProvider: { .authorized }
        )

        let aliases = await provider.aliases(knownEmails: ["kevin@example.com"])

        XCTAssertEqual(aliases, ["kevin@example.com"])
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
    private let enumerationError: Error?
    private var _enumerateContactsCallCount = 0

    init(unifiedContacts: [CNContact], enumeratedContacts: [CNContact], enumerationError: Error? = nil) {
        self.unifiedContacts = unifiedContacts
        self.enumeratedContacts = enumeratedContacts
        self.enumerationError = enumerationError
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

        // A failure after the cards above were handed over: a walk that
        // stopped part way.
        if let enumerationError {
            throw enumerationError
        }
    }
}
#endif
