import XCTest
import Contacts
@testable import esc_chatmail

/// `ContactsAppLink` hands contacts to the Mac's Contacts app. Its URL and vCard helpers are
/// platform-neutral, so they are pinned here on iOS.
///
/// HONEST SCOPE: whether Contacts opens the card or imports the vCard needs a Mac and its
/// Contacts app; the `open…` functions are Mac-only and not exercised here.
final class ContactsAppLinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactsAppLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    /// A Mac contact identifier (`<UUID>:ABPerson`) must survive `URL(string:)` intact, or the
    /// card link opens the wrong card or nothing.
    func testCardURL_macContactIdentifier_isAddressBookURLWithIdentifier() throws {
        let identifier = "410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson"

        let url = try XCTUnwrap(ContactsAppLink.cardURL(forContactIdentifier: " \(identifier)\n"))

        XCTAssertEqual(url.absoluteString, "addressbook://\(identifier)")
    }

    /// Revert-check: removing `guard !trimmed.isEmpty` from
    /// `ContactsAppLink.cardURL(forContactIdentifier:)` makes this fail.
    func testCardURL_blankIdentifier_isNil() {
        XCTAssertNil(ContactsAppLink.cardURL(forContactIdentifier: "  "))
    }

    /// The vCard must carry the prefilled name and address, or Contacts imports a blank card.
    func testWriteNewContactCard_prefilledContact_writesVCardWithNameAndEmail() throws {
        let contact = makeContact(givenName: "Ada", familyName: "Lovelace", email: "ada@example.com")

        let url = try ContactsAppLink.writeNewContactCard(for: contact, in: directory)

        XCTAssertEqual(url.lastPathComponent, "Ada Lovelace.vcf")
        let imported = try CNContactVCardSerialization.contacts(with: Data(contentsOf: url))
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.givenName, "Ada")
        XCTAssertEqual(imported.first?.familyName, "Lovelace")
        XCTAssertEqual(imported.first?.emailAddresses.map { String($0.value) }, ["ada@example.com"])
    }

    /// Only the newest card stays on disk, so at most one correspondent's details linger in the
    /// temporary directory.
    ///
    /// Revert-check: removing the `removeItem(at: folder)` call from
    /// `ContactsAppLink.writeNewContactCard(for:in:)` makes this fail.
    func testWriteNewContactCard_secondCard_replacesFirst() throws {
        _ = try ContactsAppLink.writeNewContactCard(
            for: makeContact(givenName: "Ada", familyName: "Lovelace", email: "ada@example.com"),
            in: directory
        )
        let second = try ContactsAppLink.writeNewContactCard(
            for: makeContact(givenName: "Grace", familyName: "Hopper", email: "grace@example.com"),
            in: directory
        )

        let folder = directory.appendingPathComponent(ContactsAppLink.newContactCardsFolderName)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files, [second.lastPathComponent])
    }

    /// Revert-check: dropping the email fallback from `ContactsAppLink.cardFileName(for:)` makes
    /// the nameless case fail; dropping the replacement of `/` and `:` makes the first fail.
    func testCardFileName_sanitizesAndFallsBack() {
        XCTAssertEqual(
            ContactsAppLink.cardFileName(for: makeContact(givenName: "A/B", familyName: "C:D", email: "x@example.com")),
            "A-B C-D.vcf"
        )
        XCTAssertEqual(
            ContactsAppLink.cardFileName(for: makeContact(givenName: "", familyName: "", email: "x@example.com")),
            "x@example.com.vcf"
        )
        XCTAssertEqual(
            ContactsAppLink.cardFileName(for: makeContact(givenName: "", familyName: "", email: nil)),
            "Contact.vcf"
        )
    }

    private func makeContact(givenName: String, familyName: String, email: String?) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = familyName
        if let email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }
        return contact
    }
}
