import XCTest
import Contacts
@testable import esc_chatmail

/// Pins when `ContactLinkedAddressStore` reads the address book and what it
/// does with an address book it cannot read. The address book here is a stub
/// and the defaults a suite of the test's own: nothing reads the real
/// Contacts or `UserDefaults.standard`.
final class ContactLinkedAddressStoreTests: XCTestCase {
    private static let work = "morgan@corp.example"
    private static let home = "m.vale@mail.example"

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!
    private var addressBook: AddressBookStub!

    override func setUp() {
        super.setUp()
        suiteName = "ContactLinkedAddressStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        notificationCenter = NotificationCenter()
        addressBook = AddressBookStub(cards: [[Self.work, Self.home]])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        notificationCenter = nil
        addressBook = nil
        super.tearDown()
    }

    func testRefreshIfNeeded_firstCall_adoptsWhatContactsSay() {
        let store = makeStore()
        XCTAssertTrue(store.snapshot().isEmpty, "Nothing is read until the cleanup step asks")

        let adopted = store.refreshIfNeeded()

        XCTAssertEqual(adopted.groups, [[Self.home, Self.work]])
        XCTAssertEqual(store.snapshot(), adopted)
    }

    // Revert-check: the `defaults?.set(encoded, …)` write in
    // `ContactLinkedAddressStore.refreshIfNeeded` and the read of it in
    // `init`. Without either, a launch hashes with nothing linked until its
    // first sync ends, and that sync's mail from a second address opens a
    // second chat.
    func testInit_afterAnEarlierAdoption_startsWithTheStoredLinksWithoutReading() {
        let adopted = makeStore().refreshIfNeeded()
        let nextLaunchAddressBook = AddressBookStub(cards: [[Self.work, Self.home]])

        let nextLaunch = makeStore(addressBook: nextLaunchAddressBook)

        XCTAssertEqual(nextLaunch.snapshot(), adopted)
        XCTAssertEqual(nextLaunchAddressBook.readCount, 0)
    }

    // Revert-check: the `guard !isCurrent` return in `refreshIfNeeded`. This
    // runs at the end of every sync; without the guard each one walks the
    // whole address book.
    func testRefreshIfNeeded_contactsUnchanged_doesNotReadAgain() {
        let store = makeStore()

        store.refreshIfNeeded()
        store.refreshIfNeeded()

        XCTAssertEqual(addressBook.readCount, 1)
    }

    // Revert-check: the `CNContactStoreDidChange` observer in
    // `ContactLinkedAddressStore.init`. Without it a card edited while the
    // app runs is not read until the next launch.
    func testRefreshIfNeeded_afterContactsChanged_readsAgainAndAdopts() {
        let store = makeStore()
        store.refreshIfNeeded()

        addressBook.cards = [[Self.work, Self.home, "third@x.example"]]
        notificationCenter.post(name: .CNContactStoreDidChange, object: nil)
        let adopted = store.refreshIfNeeded()

        XCTAssertEqual(addressBook.readCount, 2)
        XCTAssertEqual(adopted.groups, [[Self.home, Self.work, "third@x.example"]])
        XCTAssertEqual(makeStore(addressBook: AddressBookStub(cards: nil)).snapshot(), adopted)
    }

    // Revert-check: the `guard let contactAddressLists … else { return current }`
    // in `refreshIfNeeded`. Reading "cannot read" as "nothing is linked"
    // would unlink every chat for as long as Contacts are unreadable.
    func testRefreshIfNeeded_contactsUnreadable_keepsTheAdoptedLinksAndTriesAgain() {
        let store = makeStore()
        let adopted = store.refreshIfNeeded()

        addressBook.cards = nil
        store.markContactsChanged()
        XCTAssertEqual(store.refreshIfNeeded(), adopted)
        XCTAssertEqual(store.snapshot(), adopted)
        XCTAssertEqual(makeStore(addressBook: AddressBookStub(cards: nil)).snapshot(), adopted)

        // Readable again, with nothing reported in between: the failed read
        // left the change unread, so this call reads.
        addressBook.cards = [["k@x.example", "k2@x.example"]]
        let readsBefore = addressBook.readCount
        let later = store.refreshIfNeeded()

        XCTAssertEqual(addressBook.readCount, readsBefore + 1)
        XCTAssertEqual(later.groups, [["k2@x.example", "k@x.example"]])
    }

    /// A read that fails every time is tried again at every call, and
    /// nothing is linked.
    func testRefreshIfNeeded_neverReadable_staysEmptyAndKeepsAsking() {
        addressBook.cards = nil
        let store = makeStore()

        XCTAssertTrue(store.refreshIfNeeded().isEmpty)
        XCTAssertTrue(store.refreshIfNeeded().isEmpty)

        XCTAssertEqual(addressBook.readCount, 2)
        XCTAssertNil(defaults.string(forKey: ContactLinkedAddressStore.adoptedLinksDefaultsKey))
    }

    func testRefreshIfNeeded_cardNoLongerLinksAnything_clearsTheStoredLinks() {
        let store = makeStore()
        store.refreshIfNeeded()
        XCTAssertNotNil(defaults.string(forKey: ContactLinkedAddressStore.adoptedLinksDefaultsKey))

        addressBook.cards = [[Self.work]]
        store.markContactsChanged()
        let adopted = store.refreshIfNeeded()

        XCTAssertTrue(adopted.isEmpty)
        XCTAssertNil(defaults.string(forKey: ContactLinkedAddressStore.adoptedLinksDefaultsKey))
    }

    // Revert-check: the read of `appliedLinksDefaultsKey` in
    // `ContactLinkedAddressStore.init`. Without it every launch finds nothing
    // applied, and its first cleanup reads every linked person's
    // conversations again.
    func testMarkAppliedToConversations_isKeptForTheNextLaunch() {
        let store = makeStore()
        let adopted = store.refreshIfNeeded()
        XCTAssertTrue(store.appliedToConversations().isEmpty, "Adopting a map applies it to nothing")

        store.markAppliedToConversations(adopted)

        XCTAssertEqual(store.appliedToConversations(), adopted)
        XCTAssertEqual(
            makeStore(addressBook: AddressBookStub(cards: nil)).appliedToConversations(),
            adopted
        )

        store.markAppliedToConversations(.none)
        XCTAssertTrue(makeStore(addressBook: AddressBookStub(cards: nil)).appliedToConversations().isEmpty)
        XCTAssertNil(defaults.string(forKey: ContactLinkedAddressStore.appliedLinksDefaultsKey))
    }

    // MARK: - Contacts access

    // Revert-check: the `access == .withdrawn` branch at the top of
    // `ContactLinkedAddressStore.refreshIfNeeded`, in either of two ways.
    // Taken out, access the user turned off reads as "unreadable": the links
    // stay in use and the cards' addresses stay in defaults for good. Moved
    // below the `isCurrent` guard, it is asked only once Contacts report a
    // change, and turning access off reports none.
    func testRefreshIfNeeded_contactsAccessWithdrawn_dropsTheLinksAndTheirStoredCopy() {
        for status in [CNAuthorizationStatus.denied, .restricted] {
            addressBook.authorization = .authorized
            let store = makeStore()
            XCTAssertFalse(store.refreshIfNeeded().isEmpty)
            XCTAssertNotNil(defaults.string(forKey: ContactLinkedAddressStore.adoptedLinksDefaultsKey))
            let readsBefore = addressBook.readCount

            // No change in Contacts is reported: the app only lost its access.
            addressBook.authorization = status
            let adopted = store.refreshIfNeeded()

            XCTAssertTrue(adopted.isEmpty, "\(status.rawValue)")
            XCTAssertTrue(store.snapshot().isEmpty, "\(status.rawValue)")
            XCTAssertNil(
                defaults.string(forKey: ContactLinkedAddressStore.adoptedLinksDefaultsKey),
                "The stored map is a copy of the cards' addresses"
            )
            XCTAssertTrue(makeStore().snapshot().isEmpty, "The next launch starts with nothing linked")
            XCTAssertEqual(addressBook.readCount, readsBefore, "Nothing is read without access")
        }
    }

    // Revert-check: `generationOfAdoptedRead = 0` in
    // `ContactLinkedAddressStore.dropAdoptedLinks`. Without it the read made
    // before access was taken away still counts as current, so access given
    // back links nothing until a card is edited or the app is launched again.
    func testRefreshIfNeeded_accessGivenBackAfterWithdrawal_readsAgainWithNoChangeInContacts() {
        let store = makeStore()
        let linked = store.refreshIfNeeded()
        addressBook.authorization = .denied
        XCTAssertTrue(store.refreshIfNeeded().isEmpty)
        let readsBefore = addressBook.readCount

        addressBook.authorization = .authorized
        let adopted = store.refreshIfNeeded()

        XCTAssertEqual(adopted, linked)
        XCTAssertEqual(addressBook.readCount, readsBefore + 1)
    }

    // Revert-check: `ContactsAccess.undecided` standing apart from
    // `.withdrawn` (`ContactsAccess.init`), and the `access == .readable`
    // guard before the read in `refreshIfNeeded`. A question nobody has
    // answered is not a refusal: read as one, a privacy reset would unlink
    // every chat before the user is asked again.
    func testRefreshIfNeeded_accessNotYetDecided_keepsTheAdoptedLinksAndReadsNothing() {
        let adopted = makeStore().refreshIfNeeded()
        let nextLaunchAddressBook = AddressBookStub(cards: [], authorization: .notDetermined)
        let nextLaunch = makeStore(addressBook: nextLaunchAddressBook)

        XCTAssertEqual(nextLaunch.refreshIfNeeded(), adopted)
        XCTAssertEqual(nextLaunch.snapshot(), adopted)
        XCTAssertNotNil(defaults.string(forKey: ContactLinkedAddressStore.adoptedLinksDefaultsKey))
        XCTAssertEqual(nextLaunchAddressBook.readCount, 0)

        // Answered with a yes: the same store reads at its next call.
        nextLaunchAddressBook.authorization = .authorized
        XCTAssertTrue(nextLaunch.refreshIfNeeded().isEmpty, "These Contacts link nothing")
        XCTAssertEqual(nextLaunchAddressBook.readCount, 1)
    }

    func testContactsAccess_authorizationStatus_saysWhatTheStoreMayDo() {
        typealias Access = ContactLinkedAddressStore.ContactsAccess

        XCTAssertEqual(Access(.authorized), .readable)
        XCTAssertEqual(Access(.notDetermined), .undecided)
        XCTAssertEqual(Access(.denied), .withdrawn)
        XCTAssertEqual(Access(.restricted), .withdrawn)
        #if os(iOS)
        if #available(iOS 18.0, *) {
            XCTAssertEqual(Access(.limited), .readable, "The cards the user chose may be read")
        }
        #endif
    }

    // MARK: - Helpers

    private func makeStore(addressBook: AddressBookStub? = nil) -> ContactLinkedAddressStore {
        let addressBook = addressBook ?? self.addressBook!
        return ContactLinkedAddressStore(
            defaults: defaults,
            notificationCenter: notificationCenter,
            contactsAuthorizationStatus: { addressBook.authorization },
            loadContactAddressLists: { addressBook.read() }
        )
    }
}
