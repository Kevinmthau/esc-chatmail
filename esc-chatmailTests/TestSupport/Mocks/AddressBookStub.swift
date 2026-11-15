import Contacts
import Foundation

/// Stands in for the address book of a `ContactLinkedAddressStore`: the cards
/// it holds (nil while the read fails), the app's Contacts authorization, and
/// how often the cards were read. Pass `read` as the store's
/// `loadContactAddressLists` and `authorization` as its
/// `contactsAuthorizationStatus`; nothing here touches the real Contacts.
///
/// `@unchecked Sendable`: `lock` guards every stored property.
final class AddressBookStub: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCards: [[String]]?
    private var storedAuthorization: CNAuthorizationStatus
    private var storedReadCount = 0

    init(cards: [[String]]?, authorization: CNAuthorizationStatus = .authorized) {
        storedCards = cards
        storedAuthorization = authorization
    }

    var cards: [[String]]? {
        get { lock.withLock { storedCards } }
        set { lock.withLock { storedCards = newValue } }
    }

    var authorization: CNAuthorizationStatus {
        get { lock.withLock { storedAuthorization } }
        set { lock.withLock { storedAuthorization = newValue } }
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func read() -> [[String]]? {
        lock.withLock {
            storedReadCount += 1
            return storedCards
        }
    }
}
