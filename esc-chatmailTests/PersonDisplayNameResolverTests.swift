import XCTest
@testable import esc_chatmail

final class PersonDisplayNameResolverTests: XCTestCase {
    func testSanitizedExplicitDisplayName_preservesAllLetterBrandMatchingDomain() {
        let result = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "github",
            forEmail: "github@github.com"
        )

        XCTAssertEqual(result, "github")
    }

    func testSanitizedExplicitDisplayName_omitsPlainRawLocalPartWithoutBrandSignal() {
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "john",
            forEmail: "john@example.com"
        ))
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "noreply",
            forEmail: "noreply@example.com"
        ))
    }

    func testSenderDisplayName_usesExplicitAllLetterBrandMatchingEmailLocalPart() {
        let result = PersonDisplayNameResolver.senderDisplayName(
            email: "github@github.com",
            contactDisplayName: nil,
            headerDisplayName: "github",
            storedDisplayName: nil
        )

        XCTAssertEqual(result, "github")
    }

    func testParticipantDisplayName_marksExplicitAllLetterBrandAsReal() {
        let result = PersonDisplayNameResolver.participantDisplayName(
            email: "github@github.com",
            contactDisplayName: nil,
            headerDisplayName: "github",
            storedDisplayName: nil
        )

        XCTAssertEqual(result.name, "github")
        XCTAssertTrue(result.isReal)
    }
}
