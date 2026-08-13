import XCTest
@testable import esc_chatmail

final class ParsedListIdTests: XCTestCase {

    func testParse_phraseAndBracketedId() {
        let parsed = ParsedListId.parse("Friends of Bob <friends-of-bob.example.com>")
        XCTAssertEqual(parsed, ParsedListId(id: "friends-of-bob.example.com", title: "Friends of Bob"))
    }

    func testParse_bareBracketedId() {
        let parsed = ParsedListId.parse("<swift-evolution.swift.org>")
        XCTAssertEqual(parsed, ParsedListId(id: "swift-evolution.swift.org", title: nil))
    }

    func testParse_quotedPhraseStripsQuotes() {
        let parsed = ParsedListId.parse("\"Lena's Personnel Announcements\" <1614867.xt.local>")
        XCTAssertEqual(parsed, ParsedListId(id: "1614867.xt.local", title: "Lena's Personnel Announcements"))
    }

    func testParse_githubStyleRepoPhrase() {
        let parsed = ParsedListId.parse("owner/repo <repo.owner.github.com>")
        XCTAssertEqual(parsed, ParsedListId(id: "repo.owner.github.com", title: "owner/repo"))
    }

    func testParse_mailchimpIdentifierPhraseIsNotUsedAsDisplayTitle() {
        let parsed = ParsedListId.parse(
            "d90192af1525703adec3d3919mc list <d90192af1525703adec3d3919.657565.list-id.mcsv.net>"
        )

        XCTAssertEqual(parsed?.id, "d90192af1525703adec3d3919.657565.list-id.mcsv.net")
        XCTAssertNil(parsed?.title)
    }

    func testParse_brevoIdentifierPhraseIsNotUsedAsDisplayTitle() {
        // Revert-check: the bare-token empty-suffix rule in
        // ParsedListId.isIdentifierDerivedDisplayTitle. Brevo restates the
        // opaque list token alone in the phrase position, so it must fall
        // back exactly like a bare-header List-Id.
        let parsed = ParsedListId.parse(
            "ODI2OTI3Ny04MTYyNi0z <ODI2OTI3Ny04MTYyNi0z.list-id.mailin.fr>"
        )

        XCTAssertEqual(parsed?.id, "odi2oti3ny04mtyyni0z.list-id.mailin.fr")
        XCTAssertNil(parsed?.title)
    }

    func testParse_bareTokenPhraseBeforeListIdLabelIsNotUsedAsDisplayTitle() {
        // Revert-check: the "list-id" structural disjunct in
        // ParsedListId.isIdentifierDerivedDisplayTitle. This token is short
        // and digit-light, so only its position ahead of the literal
        // "list-id" label marks it as machine metadata.
        let parsed = ParsedListId.parse("abc123 <abc123.list-id.mailin.fr>")

        XCTAssertEqual(parsed?.id, "abc123.list-id.mailin.fr")
        XCTAssertNil(parsed?.title)
    }

    func testParse_bareTokenPhraseEqualToInterleavedLabelIsNotUsedAsDisplayTitle() {
        // Revert-check: the digit-sparse disjunct of
        // ParsedListId.isOpaqueIdentifierKey (digits >= 4 with transitions
        // >= 6); there is no "list-id" label here, so token shape alone must
        // flag base64-style identifiers.
        let parsed = ParsedListId.parse(
            "abc1defg2hij3klm4nopq5 <abc1defg2hij3klm4nopq5.campaigns.example.net>"
        )

        XCTAssertEqual(parsed?.id, "abc1defg2hij3klm4nopq5.campaigns.example.net")
        XCTAssertNil(parsed?.title)
    }

    func testParse_singleWordHumanPhraseEqualToLeadingLabelIsPreserved() {
        // A human single-word phrase matching its own label must survive the
        // bare-token rule: short, digit-free labels are not opaque.
        let parsed = ParsedListId.parse("Announcements <announcements.example.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "announcements.example.com", title: "Announcements")
        )
    }

    func testParse_multiWordPhraseBeforeListIdLabelIsPreserved() {
        // Revert-check: the titleIsBareToken gate shared by the structural
        // "list-id" disjunct — a human phrase must survive even on an ESP
        // domain whose leading label always counts as a machine identifier.
        let parsed = ParsedListId.parse("My Newsletter <mynewsletter.list-id.provider.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "mynewsletter.list-id.provider.com", title: "My Newsletter")
        )
    }

    func testParse_symbolOnlyLabelCannotMarkTitleAsIdentifierDerived() {
        // Revert-check: the !labelKey.isEmpty guard in
        // ParsedListId.isIdentifierDerivedDisplayTitle. A symbol-only label
        // has an empty alphanumeric key, and hasPrefix("") matches every
        // title; combined with the structural "list-id" rule it would flag
        // any phrase whose whole key lands in the suffix allowlist.
        let parsed = ParsedListId.parse("mc list <-.list-id.mailin.fr>")

        XCTAssertEqual(parsed, ParsedListId(id: "-.list-id.mailin.fr", title: "mc list"))
    }

    func testParse_digitHeavyHumanPhraseRelatedToListIdIsPreserved() {
        // Revert-check: the titleIsBareToken gate in
        // ParsedListId.isIdentifierDerivedDisplayTitle — this label key passes
        // the opaqueness profile, so only the phrase's internal whitespace
        // keeps the title alive. Keep the phrase multi-word when editing.
        let parsed = ParsedListId.parse(
            "Formula 1 2024 Round 12 Highlights <formula1-2024-round12-highlights.community.example>"
        )

        XCTAssertEqual(
            parsed,
            ParsedListId(
                id: "formula1-2024-round12-highlights.community.example",
                title: "Formula 1 2024 Round 12 Highlights"
            )
        )
    }

    func testParse_normalizesCaseAndWhitespace() {
        let parsed = ParsedListId.parse("  News  < LIST.Example.COM >  ")
        XCTAssertEqual(parsed, ParsedListId(id: "list.example.com", title: "News"))
    }

    func testParse_bracketlessValueUsedWhole() {
        let parsed = ParsedListId.parse("announce.example.com")
        XCTAssertEqual(parsed, ParsedListId(id: "announce.example.com", title: nil))
    }

    func testParse_nilEmptyAndWhitespaceReturnNil() {
        XCTAssertNil(ParsedListId.parse(nil))
        XCTAssertNil(ParsedListId.parse(""))
        XCTAssertNil(ParsedListId.parse("   \n"))
    }

    func testParse_emptyBracketsReturnNil() {
        XCTAssertNil(ParsedListId.parse("<>"))
        XCTAssertNil(ParsedListId.parse("Phrase <  >"))
    }

    func testParse_whitespaceInsideIdReturnsNil() {
        XCTAssertNil(ParsedListId.parse("<not a list id>"))
        XCTAssertNil(ParsedListId.parse("bare value with spaces"))
    }

    func testParse_unterminatedBracketReturnsNil() {
        XCTAssertNil(ParsedListId.parse("Phrase <list.example.com"))
    }

    func testParse_lastBracketPairWins() {
        let parsed = ParsedListId.parse("Weird <phrase> <real.example.com>")
        XCTAssertEqual(parsed, ParsedListId(id: "real.example.com", title: "Weird <phrase>"))
    }

    func testListConversationHash_distinctFromParticipantHashForSameString() {
        XCTAssertNotEqual(
            calculateListConversationHash(fromNormalizedListId: "alice@example.com"),
            calculateParticipantHash(from: ["alice@example.com"])
        )
    }

    func testListConversationHash_deterministicAndIdSensitive() {
        XCTAssertEqual(
            calculateListConversationHash(fromNormalizedListId: "list.example.com"),
            calculateListConversationHash(fromNormalizedListId: "list.example.com")
        )
        XCTAssertNotEqual(
            calculateListConversationHash(fromNormalizedListId: "list.example.com"),
            calculateListConversationHash(fromNormalizedListId: "other.example.com")
        )
    }
}
