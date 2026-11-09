import Foundation
import Contacts
#if os(macOS)
import AppKit
#endif

/// Hands a contact to the system Contacts app, the Mac's replacement for ContactsUI's in-app
/// contact screens (`AddContactView`, `ContactPresenter` and `ContactPickerView`, all iOS-only).
///
/// The URL and vCard helpers are platform-neutral so iOS tests cover them; only the `open…`
/// functions, which launch the Contacts app, are Mac-only.
enum ContactsAppLink {
    /// The URL that opens a contact's card in the Contacts app (`addressbook://<identifier>`),
    /// or nil for a blank identifier. A Mac contact identifier has the form `<UUID>:ABPerson`,
    /// which `URL(string:)` accepts as is.
    static func cardURL(forContactIdentifier identifier: String) -> URL? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "addressbook://\(trimmed)")
    }

    /// The name of the folder under the temporary directory that holds the vCard handed to
    /// Contacts for a new contact.
    static let newContactCardsFolderName = "NewContactCards"

    /// Writes `contact` as the only vCard in `directory/NewContactCards`, replacing any card
    /// written before, and returns the file's URL.
    ///
    /// Opening the file shows Contacts' own import confirmation, so nothing is added to the
    /// address book until the user accepts there. The previous card is deleted rather than kept:
    /// Contacts reads the file after `open` returns, so the newest one has to stay, and deleting
    /// the rest keeps at most one correspondent's name and address on disk.
    static func writeNewContactCard(for contact: CNContact, in directory: URL) throws -> URL {
        let data = try CNContactVCardSerialization.data(with: [contact])
        let folder = directory.appendingPathComponent(newContactCardsFolderName, isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(cardFileName(for: contact))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `<full name>.vcf`, else `<first email>.vcf`, else `Contact.vcf`, with characters that
    /// cannot appear in a file name replaced. Contacts shows the file name while it imports.
    static func cardFileName(for contact: CNContact) -> String {
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstEmail = contact.emailAddresses.first.map { String($0.value) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseName = [fullName, firstEmail].first { !$0.isEmpty } ?? "Contact"
        let sanitized = baseName
            .map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        return String(sanitized) + ".vcf"
    }

    #if os(macOS)
    /// Opens the contact's card in the Contacts app, or the app itself when the identifier makes
    /// no URL or the URL does not open.
    @MainActor
    static func openCard(identifier: String) {
        guard let url = cardURL(forContactIdentifier: identifier),
              NSWorkspace.shared.open(url) else {
            Log.warning("Could not open the contact card in Contacts; opening the app instead", category: .ui)
            openContactsApp()
            return
        }
    }

    /// Hands `contact` to the Contacts app as a vCard, so the user can review and add it there.
    @MainActor
    static func openNewContact(_ contact: CNContact) {
        do {
            let url = try writeNewContactCard(for: contact, in: FileManager.default.temporaryDirectory)
            guard NSWorkspace.shared.open(url) else {
                Log.error("Contacts did not open the new contact card", category: .ui)
                return
            }
        } catch {
            Log.error("Could not write the new contact card for Contacts", category: .ui, error: error)
        }
    }

    /// Launches (or activates) the Contacts app.
    @MainActor
    static func openContactsApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AddressBook") else {
            Log.error("The Contacts app was not found", category: .ui)
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif
}
