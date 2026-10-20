import XCTest
import Contacts
@testable import esc_chatmail

@MainActor
final class NewContactPrefillPolicyTests: XCTestCase {
    private typealias Components = NewContactPrefillPolicy.NameComponents

    private let jacobEmail = "jacob.laycock@studs.com"

    // MARK: - prefill(for:storedDisplayName:)

    /// The reported bug: the Participants row for a sender the header names "Jacob Laycock" must
    /// open Create New Contact with that name split, not with the email alone, and not with the
    /// stored Person name, which can hold the address itself.
    ///
    /// Revert-check: returning `Prefill(email:name: nil)` unconditionally from
    /// `NewContactPrefillPolicy.prefill(for:storedDisplayName:)` (the email-only prefill the user
    /// saw), or preferring `storedDisplayName` over a real row name there, fails this test.
    func testPrefill_realRowName_prefillsSplitNameAndEmail() {
        let prefill = NewContactPrefillPolicy.prefill(
            for: ParticipantLoader.ResolvedParticipant(
                email: jacobEmail,
                displayName: "Jacob Laycock",
                isRealDisplayName: true,
                contactIdentifier: nil
            ),
            storedDisplayName: "Jake"
        )

        XCTAssertEqual(prefill, NewContactPrefillPolicy.Prefill(
            email: jacobEmail,
            name: Components(givenName: "Jacob", familyName: "Laycock")
        ))
    }

    /// A row the resolver could not name reads "Unknown Contact"; that placeholder must never
    /// become the new contact's given name.
    ///
    /// HONEST SCOPE: two guards reject this placeholder, the `isRealDisplayName` check in
    /// `NewContactPrefillPolicy.prefill(for:storedDisplayName:)` and the placeholder list behind
    /// `PersonDisplayNameResolver.sanitizedExplicitDisplayName`, so reverting either one alone
    /// leaves this green. `testPrefill_nameTheResolverRejected_prefillsEmailOnly` pins the first.
    func testPrefill_unknownContactRow_prefillsEmailOnly() {
        let prefill = NewContactPrefillPolicy.prefill(
            for: ParticipantLoader.ResolvedParticipant(
                email: jacobEmail,
                displayName: PersonDisplayNameResolver.fallbackConversationName(),
                isRealDisplayName: false,
                contactIdentifier: nil
            ),
            storedDisplayName: nil
        )

        XCTAssertEqual(prefill, NewContactPrefillPolicy.Prefill(email: jacobEmail, name: nil))
    }

    /// `isRealDisplayName` is the resolver's verdict; a row name it did not accept is not
    /// prefilled even when it would parse as a name.
    ///
    /// Revert-check: dropping the `participant.isRealDisplayName` check in
    /// `NewContactPrefillPolicy.prefill(for:storedDisplayName:)` (always using the row name)
    /// fails this test.
    func testPrefill_nameTheResolverRejected_prefillsEmailOnly() {
        let prefill = NewContactPrefillPolicy.prefill(
            for: ParticipantLoader.ResolvedParticipant(
                email: jacobEmail,
                displayName: "Jacob Laycock",
                isRealDisplayName: false,
                contactIdentifier: nil
            ),
            storedDisplayName: nil
        )

        XCTAssertNil(prefill.name)
    }

    /// A participant only ever To/Cc'd as "Jacob Laycock" <jacob.laycock@…> has that name stored
    /// on his Person, which the resolver rejects for the row (it restates the address) but the
    /// removed Person-based prefill used. The add screen keeps it; an address-shaped stored name
    /// is still not a name.
    ///
    /// Revert-check: replacing `storedDisplayName` with nil in
    /// `NewContactPrefillPolicy.prefill(for:storedDisplayName:)` fails this test.
    func testPrefill_unnamedRowWithStoredName_prefillsStoredName() {
        let unnamedRow = ParticipantLoader.ResolvedParticipant(
            email: jacobEmail,
            displayName: PersonDisplayNameResolver.fallbackConversationName(),
            isRealDisplayName: false,
            contactIdentifier: nil
        )

        XCTAssertEqual(
            NewContactPrefillPolicy.prefill(for: unnamedRow, storedDisplayName: "Jacob Laycock").name,
            Components(givenName: "Jacob", familyName: "Laycock")
        )
        XCTAssertNil(NewContactPrefillPolicy.prefill(for: unnamedRow, storedDisplayName: jacobEmail).name)
    }

    // MARK: - nameComponents(forDisplayName:email:)

    func testNameComponents_firstLast_splitsGivenAndFamily() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jacob Laycock", email: jacobEmail),
            Components(givenName: "Jacob", familyName: "Laycock")
        )
    }

    func testNameComponents_singleToken_isGivenNameOnly() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jacob", email: jacobEmail),
            Components(givenName: "Jacob")
        )
    }

    /// Revert-check: removing the two-segment "Last, First" branch in
    /// `NewContactPrefillPolicy.nameComponents` (so the comma name splits on whitespace) fails this test.
    func testNameComponents_lastCommaFirst_swapsIntoGivenAndFamily() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Laycock, Jacob", email: jacobEmail),
            Components(givenName: "Jacob", familyName: "Laycock")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Laycock, Jacob Robert", email: jacobEmail),
            Components(givenName: "Jacob", middleName: "Robert", familyName: "Laycock")
        )
    }

    /// Revert-check: removing `strippingWrappingQuotes` from `NewContactPrefillPolicy.cleanedDisplayName`
    /// fails the single- and typographic-quote cases (the sanitizer strips only straight double quotes).
    func testNameComponents_quotedName_stripsWrappingQuotes() {
        let expected = Components(givenName: "Jacob", familyName: "Laycock")
        for quoted in ["\"Jacob Laycock\"", "'Jacob Laycock'", "\u{201C}Jacob Laycock\u{201D}", "\u{2018}Jacob Laycock\u{2019}"] {
            XCTAssertEqual(
                NewContactPrefillPolicy.nameComponents(forDisplayName: quoted, email: jacobEmail),
                expected,
                quoted
            )
        }
    }

    /// An apostrophe inside a name is not a wrapping quote.
    func testNameComponents_innerApostrophe_isKept() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Conan O'Brien", email: "conan@example.com"),
            Components(givenName: "Conan", familyName: "O'Brien")
        )
    }

    /// An email address used as a display name is not a name: the old splitter put the whole
    /// address in the given-name field.
    ///
    /// Revert-check: replacing `PersonDisplayNameResolver.sanitizedExplicitDisplayName` in
    /// `NewContactPrefillPolicy.cleanedDisplayName` with a plain trim fails this test.
    func testNameComponents_emailAddressAsDisplayName_returnsNil() {
        for addressName in [jacobEmail, "'\(jacobEmail)'", "\"\(jacobEmail)\"", "someone.else@example.org"] {
            XCTAssertNil(
                NewContactPrefillPolicy.nameComponents(forDisplayName: addressName, email: jacobEmail),
                addressName
            )
        }
    }

    func testNameComponents_rawLocalPartOrPlaceholderOrBlank_returnsNil() {
        for notAName in ["jacob.laycock", "Unknown Contact", "Unknown Sender", "   ", ",,", ""] {
            XCTAssertNil(
                NewContactPrefillPolicy.nameComponents(forDisplayName: notAName, email: jacobEmail),
                notAName
            )
        }
        XCTAssertNil(NewContactPrefillPolicy.nameComponents(forDisplayName: nil, email: jacobEmail))
    }

    /// Revert-check: removing the `trailingQualifierRegex` strip in
    /// `NewContactPrefillPolicy.cleanedDisplayName` fails this test ("Laycock (Studs)" as family name).
    func testNameComponents_trailingQualifier_isDropped() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jacob Laycock (Studs)", email: jacobEmail),
            Components(givenName: "Jacob", familyName: "Laycock")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jacob Laycock [Studs NYC]", email: jacobEmail),
            Components(givenName: "Jacob", familyName: "Laycock")
        )
    }

    /// A relay sender's name belongs to whoever acted through the relay, not the address: a
    /// contact saved with it would label every later notification from that address with one
    /// person's name.
    ///
    /// Revert-check: removing the `containsRelayMarker` guard in
    /// `NewContactPrefillPolicy.cleanedDisplayName` fails the two "via" cases.
    func testNameComponents_relaySenderName_returnsNil() {
        XCTAssertNil(NewContactPrefillPolicy.nameComponents(
            forDisplayName: "Jacob Laycock (via Google Drive)",
            email: "drive-shares@example.com"
        ))
        XCTAssertNil(NewContactPrefillPolicy.nameComponents(
            forDisplayName: "'Jacob Laycock' via Studs Team",
            email: "team@studs.com"
        ))
        // "via" inside a word or capitalized as a name is not a relay marker.
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Olivia Smith", email: "olivia@example.com"),
            Components(givenName: "Olivia", familyName: "Smith")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Via Smith", email: "via@example.com"),
            Components(givenName: "Via", familyName: "Smith")
        )
    }

    /// Revert-check: removing the `isNoReplyAddress` guard in
    /// `NewContactPrefillPolicy.cleanedDisplayName` fails this test.
    func testNameComponents_noReplyAddress_returnsNil() {
        XCTAssertNil(NewContactPrefillPolicy.nameComponents(
            forDisplayName: "Jacob Laycock (Google Docs)",
            email: "comments-noreply@docs.google.com"
        ))
        XCTAssertNil(NewContactPrefillPolicy.nameComponents(
            forDisplayName: "Jacob Laycock",
            email: "do-not-reply@studs.com"
        ))
    }

    /// Revert-check: removing the `isCredentialAcronym` branch in
    /// `NewContactPrefillPolicy.isCommaSuffix` fails the "MBA" / "R.N." cases (the credential
    /// swaps into the given name), and peeling only one comma suffix fails "MBA, CPA".
    func testNameComponents_commaCredentialAfterFullName_goesToSuffix() {
        let janeEmail = "jane@example.com"
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jane Doe, MBA", email: janeEmail),
            Components(givenName: "Jane", familyName: "Doe", nameSuffix: "MBA")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jane Doe, R.N.", email: janeEmail),
            Components(givenName: "Jane", familyName: "Doe", nameSuffix: "R.N.")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jane Doe, MBA, CPA", email: janeEmail),
            Components(givenName: "Jane", familyName: "Doe", nameSuffix: "MBA CPA")
        )
        // After a lone surname or an all-caps name, a capitalized segment is the given name.
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Doe, JJ", email: janeEmail),
            Components(givenName: "JJ", familyName: "Doe")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "SMITH JONES, JANE", email: janeEmail),
            Components(givenName: "JANE", familyName: "SMITH JONES")
        )
    }

    func testNameComponents_middleNamesAndLowercaseParticles_splitIntoMiddleAndFamilyNames() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Mary Ann Smith", email: "mary@example.com"),
            Components(givenName: "Mary", middleName: "Ann", familyName: "Smith")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Ludwig van Beethoven", email: "lvb@example.com"),
            Components(givenName: "Ludwig", familyName: "van Beethoven")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Juan Carlos de la Cruz", email: "jc@example.com"),
            Components(givenName: "Juan", middleName: "Carlos", familyName: "de la Cruz")
        )
        // A capitalized "Van" may be a middle name; only lowercase particles join the family name.
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Eddie Van Halen", email: "eddie@example.com"),
            Components(givenName: "Eddie", middleName: "Van", familyName: "Halen")
        )
    }

    func testNameComponents_honorificAndSuffixes_goToTheirOwnFields() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Dr. Jane Smith", email: "jane@example.com"),
            Components(namePrefix: "Dr.", givenName: "Jane", familyName: "Smith")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Dr. Smith", email: "jane@example.com"),
            Components(namePrefix: "Dr.", familyName: "Smith")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jacob Laycock Jr.", email: jacobEmail),
            Components(givenName: "Jacob", familyName: "Laycock", nameSuffix: "Jr.")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Jacob Laycock, Jr.", email: jacobEmail),
            Components(givenName: "Jacob", familyName: "Laycock", nameSuffix: "Jr.")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Smith, Jane, PhD", email: "jane@example.com"),
            Components(givenName: "Jane", familyName: "Smith", nameSuffix: "PhD")
        )
    }

    /// Three or more comma segments is no recognizable name order: keep the whole name.
    func testNameComponents_manyCommaSegments_keepsWholeNameAsGivenName() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "Laycock, Jacob, Studs", email: jacobEmail),
            Components(givenName: "Laycock, Jacob, Studs")
        )
    }

    func testNameComponents_twoTokenCJKName_isFamilyNameFirst() {
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "山田 太郎", email: "taro@example.jp"),
            Components(givenName: "太郎", familyName: "山田")
        )
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "김 민수", email: "minsu@example.kr"),
            Components(givenName: "민수", familyName: "김")
        )
        // Unspaced: no reliable split, so the whole name stays a given name.
        XCTAssertEqual(
            NewContactPrefillPolicy.nameComponents(forDisplayName: "山田太郎", email: "taro@example.jp"),
            Components(givenName: "山田太郎")
        )
    }

    // MARK: - ChatContactManager.newContact(from:)

    /// Revert-check: dropping the `familyName` (or `givenName`) assignment in
    /// `ChatContactManager.newContact(from:)` fails this test.
    func testNewContact_prefillWithName_setsNameFieldsAndWorkEmail() {
        let contact = ChatContactManager.newContact(from: NewContactPrefillPolicy.Prefill(
            email: jacobEmail,
            name: Components(namePrefix: "Dr.", givenName: "Jacob", middleName: "R", familyName: "Laycock", nameSuffix: "Jr.")
        ))

        XCTAssertEqual(contact.namePrefix, "Dr.")
        XCTAssertEqual(contact.givenName, "Jacob")
        XCTAssertEqual(contact.middleName, "R")
        XCTAssertEqual(contact.familyName, "Laycock")
        XCTAssertEqual(contact.nameSuffix, "Jr.")
        XCTAssertEqual(contact.emailAddresses.map { $0.value as String }, [jacobEmail])
        XCTAssertEqual(contact.emailAddresses.first?.label, CNLabelWork)
    }

    func testNewContact_prefillWithoutName_setsEmailOnly() {
        let contact = ChatContactManager.newContact(from: NewContactPrefillPolicy.Prefill(email: jacobEmail, name: nil))

        XCTAssertEqual(contact.givenName, "")
        XCTAssertEqual(contact.familyName, "")
        XCTAssertEqual(contact.emailAddresses.map { $0.value as String }, [jacobEmail])
    }
}
