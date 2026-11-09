#if os(macOS)
import Contacts

/// The Mac's `ContactPresenter`. The iOS one (`Views/Chat/EditContactView.swift`) presents
/// ContactsUI's contact card controller over the app, which the Mac does not have; here the
/// contact opens in the Contacts app instead (`ContactsAppLink`). `ChatContactManager` calls the
/// same two methods on both platforms.
///
/// Edits made in Contacts reach the app through `.CNContactStoreDidChange`, which the
/// participants sheet and `ContactsAuthorizationCoordinator` already observe, so nothing here
/// invalidates caches by hand the way the iOS controller's delegate does.
@MainActor
final class ContactPresenter {
    static let shared = ContactPresenter()

    private init() {}

    /// Opens the contact's card in the Contacts app.
    func presentContact(identifier: String) {
        ContactsAppLink.openCard(identifier: identifier)
    }

    /// Opens `existingContact`'s card in the Contacts app so the user can add `emailToAdd` there.
    ///
    /// Not reached from today's Mac UI: "Add to Existing Contact" needs ContactsUI's picker, so
    /// the participants sheet does not offer it on the Mac (`ContactsSheet.supportsContactPicker`).
    func addEmailToContact(existingContact: CNContact, emailToAdd _: String) {
        ContactsAppLink.openCard(identifier: existingContact.identifier)
    }
}
#endif
