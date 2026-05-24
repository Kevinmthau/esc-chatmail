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
        let emails = [
            "github@updates.github.co.uk",
            "github@updates.github.com.au",
            "github@updates.github.co.nz",
            "github@updates.github.co.jp",
            "github@updates.github.com.br",
            "github@updates.github.com.in",
            "github@updates.github.co.za"
        ]

        for email in emails {
            XCTAssertEqual(
                PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                    "github",
                    forEmail: email
                ),
                "github",
                email
            )
        }
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

    func testFallbackConversationName_emptyArrayReturnsUnknownContact() {
        XCTAssertEqual(
            PersonDisplayNameResolver.fallbackConversationName(participantEmails: []),
            "Unknown Contact"
        )
    }

    func testFallbackConversationName_whitespaceOnlyReturnsUnknownContact() {
        XCTAssertEqual(
            PersonDisplayNameResolver.fallbackConversationName(participantEmails: ["", "   ", "\n"]),
            "Unknown Contact"
        )
    }

    func testFallbackConversationName_singleEmailReturnsEmailVerbatim() {
        XCTAssertEqual(
            PersonDisplayNameResolver.fallbackConversationName(participantEmails: ["alice@example.com"]),
            "alice@example.com"
        )
    }

    func testFallbackConversationName_dedupesMixedCaseDuplicatesPreservingFirstSeen() {
        let result = PersonDisplayNameResolver.fallbackConversationName(
            participantEmails: ["Bob@Example.com", "bob@example.com", "BOB@example.com"]
        )

        XCTAssertEqual(result, "Bob@Example.com")
    }

    func testFallbackConversationName_sortsCaseInsensitively() {
        let result = PersonDisplayNameResolver.fallbackConversationName(
            participantEmails: ["Bob@example.com", "alice@example.com"]
        )

        XCTAssertEqual(result, "alice@example.com, Bob@example.com")
    }

    func testFallbackConversationName_capsAtThreeWithOverflowIndicator() {
        let result = PersonDisplayNameResolver.fallbackConversationName(
            participantEmails: [
                "e@example.com",
                "d@example.com",
                "c@example.com",
                "b@example.com",
                "a@example.com"
            ]
        )

        XCTAssertEqual(result, "a@example.com, b@example.com, c@example.com +2")
    }

    func testFallbackConversationName_collapsesGmailDotAliasesAsDuplicates() {
        let result = PersonDisplayNameResolver.fallbackConversationName(
            participantEmails: ["john.doe@gmail.com", "johndoe@gmail.com"]
        )

        XCTAssertEqual(result, "john.doe@gmail.com")
    }
}
