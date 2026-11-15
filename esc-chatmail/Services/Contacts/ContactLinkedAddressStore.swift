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
/// A new map is adopted in one place only: `refreshIfNeeded()`, called by
/// `DataCleanupService.unifyConversationsByContactIfNeeded` in a sync run's
/// cleanup. There the run owns the store and the cleanup-sensitive gate is
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
/// `@unchecked Sendable`: `lock` guards `adopted`, `applied`,
/// `contactsGeneration` and `generationOfAdoptedRead`; everything else is
/// immutable after `init`.
final class ContactLinkedAddressStore: @unchecked Sendable {
    /// Under hosted unit tests the shared store reads no Contacts and no
    /// defaults: it holds `none`, so every suite that does not pass its own
    /// map hashes exactly as before links existed. A suite that tests links
    /// passes a map, or builds a store of its own.
    static let shared: ContactLinkedAddressStore = RuntimeEnvironment.isRunningUnitTests
        ? ContactLinkedAddressStore(
            defaults: nil,
            contactsAuthorizationStatus: { .notDetermined },
            loadContactAddressLists: { nil }
        )
        : ContactLinkedAddressStore()

    static let adoptedLinksDefaultsKey = "contactLinkedAddresses.adopted.v1"
    static let appliedLinksDefaultsKey = "contactLinkedAddresses.appliedToConversations.v1"

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
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var adopted: ContactLinkedAddresses
    private var applied: ContactLinkedAddresses
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
    ///   - loadContactAddressLists: The addresses of each contact card, or nil
    ///     when the read failed. Called only while the cards may be read
    ///     (`ContactsAccess.readable`). Tests pass their own of both; nothing
    ///     in a test reads the real address book or its authorization.
    init(
        defaults: UserDefaults? = .standard,
        notificationCenter: NotificationCenter = .default,
        contactsAuthorizationStatus: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        loadContactAddressLists: @escaping @Sendable () -> [[String]]? = ContactLinkedAddressStore.makeAddressBookLoader()
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.contactsAuthorizationStatus = contactsAuthorizationStatus
        self.loadContactAddressLists = loadContactAddressLists
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
    @discardableResult
    func refreshIfNeeded() -> ContactLinkedAddresses {
        // Asked at every call, before the question of whether Contacts
        // changed: access taken away is reported by no change in Contacts,
        // and on the Mac the app can go on running after it.
        let access = ContactsAccess(contactsAuthorizationStatus())
        if access == .withdrawn {
            return dropAdoptedLinks()
        }

        // Taken before the read: a change reported while the address book is
        // being walked moves the generation past this one, so the next call
        // reads again.
        let (generation, current, isCurrent) = lock.withLock {
            (contactsGeneration, adopted, generationOfAdoptedRead == contactsGeneration)
        }
        guard !isCurrent,
              access == .readable,
              let contactAddressLists = loadContactAddressLists() else {
            // Current, undecided or unreadable: keep the map. The last two
            // leave the generation unread, so a later call tries again
            // (access granted since, or a failed read).
            return current
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

    /// Contacts access was withdrawn: nothing is linked any more, and the
    /// stored copy of the cards' addresses goes with the map.
    private func dropAdoptedLinks() -> ContactLinkedAddresses {
        let didChange = lock.withLock { () -> Bool in
            // No read stands any more. Access given back is reported by no
            // change in Contacts either, so the next readable call must read.
            generationOfAdoptedRead = 0
            guard !adopted.isEmpty else { return false }
            adopted = .none
            return true
        }
        if didChange {
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

    /// The production reader: every contact card that has more than one email
    /// address, with unified contacts as one card. Nil when the read fails.
    /// The store calls it only while the cards may be read
    /// (`ContactsAccess.readable`, limited access counting as access).
    static func makeAddressBookLoader() -> @Sendable () -> [[String]]? {
        let addressBook = AddressBook()
        return { addressBook.contactAddressLists() }
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
                    // A card with one address links nothing.
                    guard contact.emailAddresses.count > 1 else { return }
                    contactAddressLists.append(contact.emailAddresses.map { String($0.value) })
                }
            } catch {
                Log.error("Failed to read contacts for linked addresses", category: .general, error: error)
                return nil
            }
            return contactAddressLists
        }
    }
}
