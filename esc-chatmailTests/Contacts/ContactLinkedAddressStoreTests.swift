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
    /// The Mac's "me" card the store reads: empty is none, nil a failed read.
    private var meCard: MeCardBox!

    override func setUp() {
        super.setUp()
        suiteName = "ContactLinkedAddressStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        notificationCenter = NotificationCenter()
        addressBook = AddressBookStub(cards: [[Self.work, Self.home]])
        meCard = MeCardBox()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        notificationCenter = nil
        addressBook = nil
        meCard = nil
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

    // MARK: - The user's own addresses

    private static let me = "me@example.com"
    private static let icloud = "me@icloud.example"

    /// The self set is adopted with the links, kept in defaults, and read back by a
    /// store a cold launch makes, before any read: it hashes as the last launch did.
    ///
    /// Revert-check: the `adoptedSelfDefaultsKey` read in `ContactLinkedAddressStore.init`.
    func testSelfAddresses_adoptedAndKeptAcrossALaunch() {
        addressBook.cards = [[Self.me, Self.icloud]]
        makeStore().refreshIfNeeded(knownAddresses: [Self.me])

        let relaunched = makeStore()

        XCTAssertEqual(relaunched.selfAddressesSnapshot(forKnown: [Self.me]), [Self.me, Self.icloud])
        XCTAssertEqual(addressBook.readCount, 1, "Answered from defaults, with no read")
    }

    /// An address book that cannot be read is never an empty self set; withdrawn access
    /// drops it, here and in defaults.
    ///
    /// Revert-check: the `adoptedSelf = nil` in `ContactLinkedAddressStore.dropAdoptedLinks`.
    func testSelfAddresses_unreadableKeepsTheSet_withdrawnDropsIt() {
        addressBook.cards = [[Self.me, Self.icloud]]
        let store = makeStore()
        store.refreshIfNeeded(knownAddresses: [Self.me])

        addressBook.cards = nil
        store.markContactsChanged()
        store.refreshIfNeeded(knownAddresses: [Self.me])
        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [Self.me, Self.icloud])

        addressBook.authorization = .denied
        store.refreshIfNeeded(knownAddresses: [Self.me])
        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [])
        XCTAssertEqual(makeStore().selfAddressesSnapshot(forKnown: [Self.me]), [], "Nothing is kept in defaults")
        XCTAssertEqual(store.legacySelfAddressesOfLastRead(), [], "Without access the old rule answered nothing too")
    }

    /// The set is decided for the account's addresses and read again when they change,
    /// with no change in Contacts to report it (a send-as address added).
    ///
    /// Revert-check: the `adoptedSelf?.knownAddresses == known` term of
    /// `ContactLinkedAddressStore.refreshIfNeeded`.
    func testSelfAddresses_accountAddressesChange_readsAgain() {
        let sendAs = "me@corp.example"
        addressBook.cards = [[sendAs, Self.icloud]]
        let store = makeStore()
        store.refreshIfNeeded(knownAddresses: [Self.me])
        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [])

        store.refreshIfNeeded(knownAddresses: [Self.me, sendAs])

        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me, sendAs]), [sendAs, Self.icloud])
        XCTAssertEqual(addressBook.readCount, 2)
    }

    /// The first read also says what the rule before the adopted set took as the
    /// user's: every address of a card listing the account's address.
    ///
    /// Revert-check: the `!card.isDisjoint(with: known)` condition of
    /// `ContactLinkedAddressStore.legacySelfAddresses` (every card's addresses count).
    func testSelfAddresses_legacySetOfTheRead_isEveryAddressOfACardListingTheAccount() {
        addressBook.cards = [[Self.me, "partner@example.com"], ["partner@example.com", "partner@work.example"]]
        let store = makeStore()
        XCTAssertNil(store.legacySelfAddressesOfLastRead())

        store.refreshIfNeeded(knownAddresses: [Self.me])

        XCTAssertEqual(store.legacySelfAddressesOfLastRead(), [Self.me, "partner@example.com"])
        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [], "The partner's own card disqualifies the household card")
    }

    /// The applied set is the account's: one recorded for an account that shares none
    /// of these addresses says nothing about this account's conversations.
    ///
    /// Revert-check: the `isDisjoint(with: known)` guard of
    /// `ContactLinkedAddressStore.appliedSelfAddresses(forKnown:)`.
    func testAppliedSelfAddresses_recordedForAnotherAccount_isNil() {
        let store = makeStore()
        store.markSelfAddressesApplied([Self.me, Self.icloud], knownAddresses: [Self.me])

        XCTAssertEqual(store.appliedSelfAddresses(forKnown: [Self.me]), [Self.me, Self.icloud])
        XCTAssertNil(store.appliedSelfAddresses(forKnown: ["next@example.com"]))
        XCTAssertEqual(makeStore().appliedSelfAddresses(forKnown: [Self.me]), [Self.me, Self.icloud], "Kept in defaults")
    }

    /// The Mac's "me" card is the user's by the user's own say: its addresses are
    /// adopted, and trusted when the cards are judged, so its own entry among the cards
    /// claims nothing and the user's card that shares an address with it still counts.
    ///
    /// Revert-check: `trustedAddresses: meCard` in
    /// `ContactLinkedAddressStore.adoptSelfAddresses` (pass `[]`).
    func testSelfAddresses_meCard_isAdoptedAndTrusted() {
        let mac = "me@mac.example"
        let alt = "me@alt.example"
        addressBook.cards = [[Self.me, mac, alt], [mac]]
        meCard.value = [mac]
        let store = makeStore()

        store.refreshIfNeeded(knownAddresses: [Self.me])

        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [Self.me, mac, alt])
    }

    /// A "me" card that could not be read is not a missing one: adopted as none, its own
    /// entry among the cards would claim its addresses for someone else and shrink the
    /// set. Nothing is adopted, and the next pass reads again.
    ///
    /// Revert-check: the `guard let meCardList = loadMeCardAddresses()` early return in
    /// `ContactLinkedAddressStore.adoptSelfAddresses` (read nil as none).
    func testSelfAddresses_meCardUnreadable_keepsTheSetAndReadsAgain() {
        let mac = "me@mac.example"
        let alt = "me@alt.example"
        addressBook.cards = [[Self.me, mac, alt], [mac]]
        meCard.value = [mac]
        let store = makeStore()
        store.refreshIfNeeded(knownAddresses: [Self.me])

        meCard.value = nil
        store.markContactsChanged()
        store.refreshIfNeeded(knownAddresses: [Self.me])

        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [Self.me, mac, alt])
        XCTAssertNil(store.legacySelfAddressesOfLastRead(), "Nothing was decided, so the next pass reads again")
    }

    #if os(iOS)
    /// Limited access walks only the cards the user shared, so the card that would
    /// disqualify a household card may be missing: no card counts.
    ///
    /// Revert-check: the `isLimitedAccess ? []` term of
    /// `ContactLinkedAddressStore.adoptSelfAddresses`.
    func testSelfAddresses_limitedAccess_admitsNoCard() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Limited access is iOS 18") }
        addressBook.cards = [[Self.me, Self.icloud]]
        addressBook.authorization = .limited
        let store = makeStore()

        store.refreshIfNeeded(knownAddresses: [Self.me])

        XCTAssertEqual(store.selfAddressesSnapshot(forKnown: [Self.me]), [])
    }
    #endif

    // MARK: - Helpers

    private func makeStore(addressBook: AddressBookStub? = nil) -> ContactLinkedAddressStore {
        let addressBook = addressBook ?? self.addressBook!
        let meCard = self.meCard!
        return ContactLinkedAddressStore(
            defaults: defaults,
            notificationCenter: notificationCenter,
            contactsAuthorizationStatus: { addressBook.authorization },
            loadContactAddressLists: { addressBook.read() },
            loadMeCardAddresses: { meCard.value }
        )
    }
}

/// `@unchecked Sendable`: `lock` guards `_value`.
private final class MeCardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String]? = []

    var value: [String]? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
