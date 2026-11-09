import SwiftUI
import Contacts

/// The Contacts sheets the chat and compose screens present.
///
/// iOS shows ContactsUI's own controllers, exactly as before the Mac port: `AddContactView` for
/// a new contact and `ContactPickerView` to choose one. ContactsUI has neither on the Mac, so
/// those files compile only for iOS, and the Mac shows `OpenInContactsSheet`, which hands the
/// contact to the Contacts app.
struct ContactsSheet: View {
    enum Kind {
        /// A prefilled contact for the user to review and save.
        case newContact(CNMutableContact)
        /// Choose an existing contact. `displayedPropertyKeys` is passed to the picker as is: nil
        /// shows its default subtitles, `[]` shows names only.
        case contactPicker(
            onContactSelected: (CNContact) -> Void,
            onCancel: () -> Void,
            displayedPropertyKeys: [String]?
        )
    }

    let kind: Kind

    /// Whether the app can let the user choose an existing contact. The Mac cannot (it has no
    /// ContactsUI picker), so callers hide the actions that lead to one there: "Add to Existing
    /// Contact" in the participants sheet and compose's contacts button.
    static var supportsContactPicker: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        #if os(iOS)
        switch kind {
        case .newContact(let contact):
            AddContactView(contact: contact)
        case let .contactPicker(onContactSelected, onCancel, displayedPropertyKeys):
            ContactPickerView(
                onContactSelected: onContactSelected,
                onCancel: onCancel,
                displayedPropertyKeys: displayedPropertyKeys
            )
        }
        #else
        switch kind {
        case .newContact(let contact):
            OpenInContactsSheet(newContact: contact)
        case let .contactPicker(_, onCancel, _):
            OpenInContactsSheet(onCancel: onCancel)
        }
        #endif
    }
}
