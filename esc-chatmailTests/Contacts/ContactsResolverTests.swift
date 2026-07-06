import XCTest
import Contacts
@testable import esc_chatmail

final class ContactsResolverTests: XCTestCase {
    func testCreateMatchUsesOrganizationNameWhenFullNameIsUnavailable() async {
        let contact = CNMutableContact()
        contact.organizationName = "Gables Station"
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "announcements@gables.example" as NSString)
        ]

        let match = await ContactsResolver.shared.createMatch(
            from: contact.copy() as! CNContact,
            email: "announcements@gables.example"
        )

        XCTAssertEqual(match.displayName, "Gables Station")
    }
}
