import Foundation
import Contacts

/// Holds the linked-address map that conversation identity hashes with
/// (`ContactLinkedAddresses`), and reads a new one from Contacts when they
/// have changed.
///
/// The adopted map is the one truth for every hash in the process: sync
/// routing, the optimistic send path and the repair passes all read
/// `snapshot()`, so they agree on which addresses are one person. It is kept
/// in defaults, because a cold launch hashes before Contacts are read again
/// and must hash as the last launch did; hashing that launch's mail with
/// nothing linked would fork every unified chat.
///
/// A new map is adopted by one function only, `refreshIfNeeded()`, called by
/// `DataCleanupService.unifyConversationsByContactIfNeeded` as the first step
/// of a sync run's cleanup and again before each run routes mail
/// (`adoptContactsBeforeRouting`). There the run owns the store and the gate is
/// held, so no sync and no optimistic send hashes between the adoption and
/// the pass that moves the stored conversations onto the new hashes. Never
/// adopt from anywhere else: a map adopted while mail is being routed routes
/// it by hashes no stored conversation carries yet.
///
/// A map that cannot be read is never an empty map. While Contacts access has
/// not been decided, or when the read fails, the adopted map stays as it is;
/// unlinking every chat because the address book was unreadable for one launch
/// would split conversations that the next launch merges again.
///
/// Access the user has denied, or the device restricts, is not that case. It
/// is an answer: the app may no longer use what Contacts said. The adopted map
/// is then dropped, here and in defaults, where it is a copy of the cards'
/// addresses; the cleanup pass that adopted nothing gives the stored
/// conversations their own hashes back and its record of the applied map goes
/// the same way. What was merged stays merged, as with any unlinking.
///
/// The store also keeps the map the stored conversations were last brought in
/// line with (`appliedToConversations()`), which that cleanup pass compares
/// with the adopted one. It is kept here and not among the migration flags so
/// that everything about linked addresses is in one place a test can leave
/// empty: a suite's service uses the shared store, which holds and writes
/// nothing under unit tests, where the flags default to the real defaults.
///
/// The map is the device's Contacts, not the signed-in account's mail, so it
/// is not part of the account boundary and outlives a sign-out. The user's own
/// addresses are left out when a hash is made, not here
/// (`ContactLinkedAddresses.canonicalAddress`).
///
/// The same read adopts the user's own addresses that Contacts add
/// (`SelfContactCards`, and the Mac's "me" card), which every hash leaves out,
/// `isFromMe` reads and reply recipients drop (`AliasManager`). They were read
/// live, at every alias lookup: an edit to any card (the partner's too) moved
/// an address in or out of the set between two hashes, and a cold launch
/// hashed with whatever the address book said then (architecture review
/// 2026-11, contacts-person#1). Now they follow the map's rules: adopted only
/// here, kept in defaults, kept when Contacts cannot be read, dropped when
/// access is withdrawn, and the stored conversations brought onto them by the
/// same cleanup pass (`appliedSelfAddresses`). The set is decided for the
/// account addresses it was read with (`AdoptedSelfAddresses.knownAddresses`),
/// is read again when they change, and answers nothing for an account that
/// shares none of them, so another account never inherits it.
///
/// `@unchecked Sendable`: `lock` guards `adopted`, `applied`, `adoptedSelf`,
/// `appliedSelf`, `legacySelfOfLastRead`, `contactsGeneration` and
/// `generationOfAdoptedRead`; everything else is immutable after `init`.
final class ContactLinkedAddressStore: @unchecked Sendable {
    /// Under hosted unit tests the shared store reads no Contacts and no
    /// defaults: it holds `none`, so every suite that does not pass its own
    /// map hashes exactly as before links existed. A suite that tests links
    /// passes a map, or builds a store of its own.
    static let shared: ContactLinkedAddressStore = RuntimeEnvironment.isRunningUnitTests
        ? ContactLinkedAddressStore(
            defaults: nil,
            contactsAuthorizationStatus: { .notDetermined },
            loadContactAddressLists: { nil },
            loadMeCardAddresses: { nil }
        )
        : ContactLinkedAddressStore()

    static let adoptedLinksDefaultsKey = "contactLinkedAddresses.adopted.v1"
    static let appliedLinksDefaultsKey = "contactLinkedAddresses.appliedToConversations.v1"
    static let adoptedSelfDefaultsKey = "contactSelfAddresses.adopted.v1"
    static let appliedSelfDefaultsKey = "contactSelfAddresses.appliedToConversations.v1"

    /// The user's own addresses Contacts add, as last adopted, and the account
    /// addresses they were decided for.
    struct AdoptedSelfAddresses: Codable, Equatable, Sendable {
        /// The account's address and send-as addresses the set was decided
        /// for, normalized.
        let knownAddresses: Set<String>
        /// The addresses the cards add, normalized: the cards that count as
        /// the user's own (`SelfContactCards`) and the Mac's "me" card.
        let addresses: Set<String>
    }

    /// What a Contacts authorization status lets the store do.
    enum ContactsAccess: Equatable, Sendable {
        /// The cards may be read: authorized, or limited to the cards the
        /// user chose.
        case readable
        /// Not decided yet. Nothing can be read and nothing was withdrawn:
        /// it is the status of a first launch, where nothing is adopted
        /// either way, and a map adopted earlier stays until the question is
        /// answered.
        case undecided
        /// Denied by the user, or restricted on the device. Nothing Contacts
        /// said may be used any more: the adopted map goes.
        case withdrawn

        init(_ status: CNAuthorizationStatus) {
            if status == .authorized || status.isLimitedAccess {
                self = .readable
            } else if status == .denied || status == .restricted {
                self = .withdrawn
            } else {
                self = .undecided
            }
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let notificationCenter: NotificationCenter
    private let contactsAuthorizationStatus: @Sendable () -> CNAuthorizationStatus
    private let loadContactAddressLists: @Sendable () -> [[String]]?
    private let loadMeCardAddresses: @Sendable () -> [String]?
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var adopted: ContactLinkedAddresses
    private var applied: ContactLinkedAddresses
    private var adoptedSelf: AdoptedSelfAddresses?
    /// The self set the stored conversations were last brought in line with,
    /// and the account addresses it was decided for.
    private var appliedSelf: AdoptedSelfAddresses?
    /// What the rule before this one would have taken as the user's from the
    /// last read in this process (every address of a card listing an account
    /// address, and the "me" card): the set the stored conversations were
    /// hashed with before `appliedSelf` was first recorded. Empty after access
    /// was withdrawn, which that rule also answered with nothing.
    private var legacySelfOfLastRead: Set<String>?
    /// Moves on every change the address book reports. Starts ahead of
    /// `generationOfAdoptedRead`, so the first call of a launch reads.
    private var contactsGeneration: UInt64 = 1
    private var generationOfAdoptedRead: UInt64 = 0

    /// - Parameters:
    ///   - defaults: Where the adopted and the applied map are kept between
    ///     launches. Nil keeps them in memory only.
    ///   - notificationCenter: Source of `CNContactStoreDidChange`.
    ///   - contactsAuthorizationStatus: The app's Contacts authorization now.
    ///     Asked at every `refreshIfNeeded()`; it is one status check.
    ///   - loadContactAddressLists: The addresses of every contact card, cards
    ///     with one address included (the self rule needs them), or nil when
    ///     the read failed. Called only while the cards may be read
    ///     (`ContactsAccess.readable`). Tests pass their own of both; nothing
    ///     in a test reads the real address book or its authorization.
    ///   - loadMeCardAddresses: The Mac's "me" card's addresses, empty where
    ///     there is none (iOS has none), or nil when it could not be read.
    init(
        defaults: UserDefaults? = .standard,
        notificationCenter: NotificationCenter = .default,
        contactsAuthorizationStatus: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        loadContactAddressLists: @escaping @Sendable () -> [[String]]? = ContactLinkedAddressStore.makeAddressBookLoader(),
        loadMeCardAddresses: @escaping @Sendable () -> [String]? = ContactLinkedAddressStore.makeMeCardLoader()
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.contactsAuthorizationStatus = contactsAuthorizationStatus
        self.loadContactAddressLists = loadContactAddressLists
        self.loadMeCardAddresses = loadMeCardAddresses
        self.adoptedSelf = defaults?.data(forKey: Self.adoptedSelfDefaultsKey)
            .flatMap { try? JSONDecoder().decode(AdoptedSelfAddresses.self, from: $0) }
        self.appliedSelf = defaults?.data(forKey: Self.appliedSelfDefaultsKey)
            .flatMap { try? JSONDecoder().decode(AdoptedSelfAddresses.self, from: $0) }
        self.adopted = ContactLinkedAddresses(
            encoded: defaults?.string(forKey: Self.adoptedLinksDefaultsKey)
        )
        self.applied = ContactLinkedAddresses(
            encoded: defaults?.string(forKey: Self.appliedLinksDefaultsKey)
        )
        self.contactsDidChangeObserver = notificationCenter.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markContactsChanged()
        }
    }

    deinit {
        if let contactsDidChangeObserver {
            notificationCenter.removeObserver(contactsDidChangeObserver)
        }
    }

    /// The adopted map. What every participant hash is made with.
    func snapshot() -> ContactLinkedAddresses {
        lock.withLock { adopted }
    }

    /// Reads Contacts again if they may have changed since the adopted map was
    /// read, adopts what they say now, and returns the adopted map.
    ///
    /// Only for `DataCleanupService.unifyConversationsByContactIfNeeded`; see
    /// the type's comment for why nothing else may adopt a map. The read is
    /// synchronous and walks the address book, so it is made only when a
    /// change was reported, a read has not yet succeeded, or the process has
    /// not read yet.
    ///
    /// - Parameter knownAddresses: The account's address and send-as
    ///   addresses. The user's own addresses Contacts add are decided for them
    ///   (`SelfContactCards`), and read again when they differ from the ones
    ///   the adopted set was decided for. Empty leaves that set as it is.
    @discardableResult
    func refreshIfNeeded(knownAddresses: some Sequence<String> = [String]()) -> ContactLinkedAddresses {
        let known = Set(knownAddresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        // Asked at every call, before the question of whether Contacts
        // changed: access taken away is reported by no change in Contacts,
        // and on the Mac the app can go on running after it.
        let status = contactsAuthorizationStatus()
        let access = ContactsAccess(status)
        if access == .withdrawn {
            return dropAdoptedLinks()
        }

        // Taken before the read: a change reported while the address book is
        // being walked moves the generation past this one, so the next call
        // reads again.
        let (generation, current, isCurrent, selfIsCurrent) = lock.withLock {
            (
                contactsGeneration,
                adopted,
                generationOfAdoptedRead == contactsGeneration,
                // Read once a process for the account's addresses too: the
                // first pass after the switch needs the old rule's set
                // (`legacySelfOfLastRead`), which only a read can give.
                known.isEmpty || (adoptedSelf?.knownAddresses == known && legacySelfOfLastRead != nil)
            )
        }
        guard !isCurrent || !selfIsCurrent,
              access == .readable,
              let contactAddressLists = loadContactAddressLists() else {
            // Current, undecided or unreadable: keep the map and the self
            // set. The last two leave the generation unread, so a later call
            // tries again (access granted since, or a failed read).
            return current
        }

        if !known.isEmpty {
            adoptSelfAddresses(
                contactAddressLists: contactAddressLists,
                knownAddresses: known,
                isLimitedAccess: status.isLimitedAccess
            )
        }

        let loaded = ContactLinkedAddresses(contactAddressLists: contactAddressLists)
        let didChange = lock.withLock { () -> Bool in
            generationOfAdoptedRead = generation
            guard adopted != loaded else { return false }
            adopted = loaded
            return true
        }
        if didChange {
            store(loaded, forKey: Self.adoptedLinksDefaultsKey)
            Log.info(
                "Adopted contact-linked addresses: \(loaded.groups.count) linked contact(s)",
                category: .conversation
            )
        }
        return loaded
    }

    /// Decides and adopts the user's own addresses the cards add. A read under
    /// limited access sees only the cards the user shared, so a partner's card
    /// that would disqualify a household card may be missing: it admits the
    /// "me" card alone, as the live read did.
    private func adoptSelfAddresses(
        contactAddressLists: [[String]],
        knownAddresses known: Set<String>,
        isLimitedAccess: Bool
    ) {
        // A "me" card that could not be read is not a missing one: without its
        // addresses trusted, its own entry among the cards would claim them for
        // someone else and disqualify the user's own card. Nothing is adopted;
        // the next pass reads again (`legacySelfOfLastRead` stays unset).
        guard let meCardList = loadMeCardAddresses() else {
            // Unset, so the next pass reads again even with no change in Contacts.
            lock.withLock { legacySelfOfLastRead = nil }
            Log.warning("Could not read the \"me\" card; keeping the user's own addresses as adopted", category: .conversation)
            return
        }
        let meCard = Set(meCardList.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        let fromCards = isLimitedAccess
            ? []
            : SelfContactCards.selfAddresses(
                contactAddressLists: contactAddressLists,
                knownAddresses: known,
                trustedAddresses: meCard
            )
        let decided = AdoptedSelfAddresses(knownAddresses: known, addresses: meCard.union(fromCards))
        let legacy = Self.legacySelfAddresses(
            contactAddressLists: contactAddressLists,
            knownAddresses: known,
            meCard: meCard
        )
        let didChange = lock.withLock { () -> Bool in
            legacySelfOfLastRead = legacy
            guard adoptedSelf != decided else { return false }
            adoptedSelf = decided
            return true
        }
        if didChange {
            defaults?.set(try? JSONEncoder().encode(decided), forKey: Self.adoptedSelfDefaultsKey)
            Log.info(
                "Adopted the user's own addresses from Contacts: \(decided.addresses.subtracting(known).count) beyond the account's",
                category: .conversation
            )
        }
    }

    /// The rule before `SelfContactCards`: every address of every card that
    /// lists an account address, and the "me" card.
    static func legacySelfAddresses(
        contactAddressLists: [[String]],
        knownAddresses known: Set<String>,
        meCard: Set<String>
    ) -> Set<String> {
        var addresses = meCard
        for list in contactAddressLists {
            let card = Set(list.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
            if !card.isDisjoint(with: known) { addresses.formUnion(card) }
        }
        return addresses
    }

    /// The user's own addresses Contacts add, for an account with these
    /// `knownAddresses`: the adopted set, or nothing when none was adopted or
    /// it was decided for an account that shares none of them. What
    /// `AliasManager` adds to the account's addresses.
    func selfAddressesSnapshot(forKnown knownAddresses: Set<String>) -> Set<String> {
        let known = Set(knownAddresses.map(EmailNormalizer.normalize))
        return lock.withLock {
            guard let adoptedSelf, !adoptedSelf.knownAddresses.isDisjoint(with: known) else { return [] }
            return adoptedSelf.addresses
        }
    }

    /// The self set every stored conversation was last brought in line with,
    /// or nil when none was recorded (no pass ran since the self set was
    /// adopted here instead of read live) or it was recorded for an account
    /// that shares none of `knownAddresses`: the stored conversations of this
    /// account were never hashed with it.
    func appliedSelfAddresses(forKnown knownAddresses: Set<String>) -> Set<String>? {
        let known = Set(knownAddresses.map(EmailNormalizer.normalize))
        return lock.withLock {
            guard let appliedSelf, !appliedSelf.knownAddresses.isDisjoint(with: known) else { return nil }
            return appliedSelf.addresses
        }
    }

    /// What the stored conversations were hashed with before
    /// `appliedSelfAddresses` was first recorded, from the last read in this
    /// process; nil when nothing was read.
    func legacySelfAddressesOfLastRead() -> Set<String>? {
        lock.withLock { legacySelfOfLastRead }
    }

    /// Records that every stored conversation carries the hashes of this self
    /// set. Only for the cleanup pass, once its repair completed.
    func markSelfAddressesApplied(_ addresses: Set<String>, knownAddresses: Set<String>) {
        let applied = AdoptedSelfAddresses(
            knownAddresses: Set(knownAddresses.map(EmailNormalizer.normalize)),
            addresses: addresses
        )
        lock.withLock { appliedSelf = applied }
        defaults?.set(try? JSONEncoder().encode(applied), forKey: Self.appliedSelfDefaultsKey)
    }

    /// Contacts access was withdrawn: nothing is linked any more, and the
    /// stored copy of the cards' addresses goes with the map.
    private func dropAdoptedLinks() -> ContactLinkedAddresses {
        let didChange = lock.withLock { () -> Bool in
            // No read stands any more. Access given back is reported by no
            // change in Contacts either, so the next readable call must read.
            generationOfAdoptedRead = 0
            // The live read answered nothing without access, so that is also
            // what the conversations were hashed with under the old rule.
            legacySelfOfLastRead = []
            let hadSelf = adoptedSelf != nil
            adoptedSelf = nil
            guard !adopted.isEmpty else { return hadSelf }
            adopted = .none
            return true
        }
        if didChange {
            defaults?.removeObject(forKey: Self.adoptedSelfDefaultsKey)
            store(.none, forKey: Self.adoptedLinksDefaultsKey)
            Log.info(
                "Dropped contact-linked addresses: Contacts access was withdrawn",
                category: .conversation
            )
        }
        return .none
    }

    /// The address book changed, so the next `refreshIfNeeded()` reads it.
    func markContactsChanged() {
        lock.withLock { contactsGeneration &+= 1 }
    }

    // MARK: - Applied to the stored conversations

    /// The map whose hashes the stored conversations carry: the one last
    /// passed to `markAppliedToConversations`, or `none` if no link was ever
    /// applied. While it differs from the adopted map, stored conversations
    /// that name a changed address still carry the old map's hashes.
    func appliedToConversations() -> ContactLinkedAddresses {
        lock.withLock { applied }
    }

    /// Records that every stored conversation carries `links`' hashes. Only
    /// for the cleanup pass, once its repair completed.
    func markAppliedToConversations(_ links: ContactLinkedAddresses) {
        lock.withLock { applied = links }
        store(links, forKey: Self.appliedLinksDefaultsKey)
    }

    private func store(_ links: ContactLinkedAddresses, forKey key: String) {
        if let encoded = links.encoded {
            defaults?.set(encoded, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Address book

    /// The production reader: every contact card that has an email address,
    /// with unified contacts as one card. Nil when the read fails. Cards with
    /// one address link nothing, but the self rule needs them: such a card
    /// claims its address for someone else (`SelfContactCards`).
    /// The store calls it only while the cards may be read
    /// (`ContactsAccess.readable`, limited access counting as access).
    static func makeAddressBookLoader() -> @Sendable () -> [[String]]? {
        let addressBook = AddressBook()
        return { addressBook.contactAddressLists() }
    }

    /// The Mac's "me" card's addresses: empty on iOS, which has no "me" card,
    /// and where none is set; nil when it could not be read.
    static func makeMeCardLoader() -> @Sendable () -> [String]? {
        #if os(macOS)
        let addressBook = AddressBook()
        return { addressBook.meCardAddresses() }
        #else
        return { [] }
        #endif
    }

    /// `@unchecked Sendable`: `CNContactStore` is documented as thread-safe,
    /// and this type holds nothing else. It keeps the one store alive for the
    /// life of the reader, because `CNContactStoreDidChange` is posted only to
    /// a process that holds a contact store.
    private final class AddressBook: @unchecked Sendable {
        private let contactStore = CNContactStore()

        func contactAddressLists() -> [[String]]? {
            let request = CNContactFetchRequest(
                keysToFetch: [CNContactEmailAddressesKey as CNKeyDescriptor]
            )
            var contactAddressLists: [[String]] = []
            do {
                try contactStore.enumerateContacts(with: request) { contact, _ in
                    guard !contact.emailAddresses.isEmpty else { return }
                    contactAddressLists.append(contact.emailAddresses.map { String($0.value) })
                }
            } catch {
                Log.error("Failed to read contacts for linked addresses", category: .general, error: error)
                return nil
            }
            return contactAddressLists
        }

        #if os(macOS)
        func meCardAddresses() -> [String]? {
            let keys = [CNContactEmailAddressesKey as CNKeyDescriptor]
            do {
                let contact = try contactStore.unifiedMeContactWithKeys(toFetch: keys)
                return contact.emailAddresses.map { String($0.value) }
            } catch let error as CNError where error.code == .recordDoesNotExist {
                // No "me" card is set: an answer, not a failed read.
                return []
            } catch {
                Log.error("Failed to read the \"me\" card", category: .general, error: error)
                return nil
            }
        }
        #endif
    }
}
