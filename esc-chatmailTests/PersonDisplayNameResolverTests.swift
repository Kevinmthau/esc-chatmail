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

    func testSanitizedExplicitDisplayName_preservesBrandMatchingOrganizationLabel() {
        let result = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "github",
            forEmail: "github@updates.github.com"
        )

        XCTAssertEqual(result, "github")
    }

    func testSanitizedExplicitDisplayName_preservesBrandMatchingOrganizationLabelUnderMultiLabelPublicSuffix() {
        XCTAssertEqual(
            PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                "github",
                forEmail: "github@updates.github.co.uk"
            ),
            "github"
        )
        XCTAssertEqual(
            PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                "github",
                forEmail: "github@updates.github.com.au"
            ),
            "github"
        )
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

    func testSanitizedExplicitDisplayName_omitsRoleLocalPartMirroredBySubdomain() {
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "noreply",
            forEmail: "noreply@noreply.example.com"
        ))
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "support",
            forEmail: "support@support.company.com"
        ))
    }

    func testSanitizedExplicitDisplayName_omitsRoleLocalPartMirroredBySubdomainUnderMultiLabelPublicSuffix() {
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "noreply",
            forEmail: "noreply@noreply.example.co.uk"
        ))
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "support",
            forEmail: "support@support.company.com.au"
        ))
    }

    func testSanitizedExplicitDisplayName_omitsMirroredLocalPartWhenSecondLevelLabelIsRegistrable() {
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "brand",
            forEmail: "brand@updates.brand.com.ch"
        ))
        XCTAssertNil(PersonDisplayNameResolver.sanitizedExplicitDisplayName(
            "brand",
            forEmail: "brand@updates.brand.com.se"
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
