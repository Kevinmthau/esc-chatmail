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

    func testParse_brevoCustomDomainBase64TokenPhraseIsNotUsedAsDisplayTitle() {
        // Revert-check: ParsedListId.isBase64EncodedNumericIdentifier. On a
        // custom sending domain no provider suffix vouches for the token, and
        // this base64 alignment ("10226015-235877-0" encodes with only two
        // literal digits) stays under both literal-digit opaqueness profiles,
        // so only decoding can mark it as machine metadata.
        let parsed = ParsedListId.parse(
            "MTAyMjYwMTUtMjM1ODc3LTA= <MTAyMjYwMTUtMjM1ODc3LTA=.list-id.email-newsletters.timeout.com>"
        )

        XCTAssertEqual(parsed?.id, "mtaymjywmtutmjm1odc3lta=.list-id.email-newsletters.timeout.com")
        XCTAssertNil(parsed?.title)
    }

    func testParse_base64AlphabetHumanWordPhraseIsPreserved() {
        // HONEST SCOPE: this cannot pin a single gate — at eight base64 chars
        // "Espresso" decodes to six bytes, under the minimum decoded length,
        // and those bytes would fail the digit-shape scan anyway. It documents
        // the verdict for short brand words; the load-bearing per-gate pins
        // are the "Newsletters" and "MS0yLTMtNC01" tests below.
        let parsed = ParsedListId.parse("Espresso <espresso.example.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "espresso.example.com", title: "Espresso")
        )
    }

    func testParse_allDigitHumanPhraseEqualToLeadingLabelIsPreserved() {
        // HONEST SCOPE: like "Espresso" above, "20242025" is rejected by the
        // decoded-length gate before the digit-shape scan runs (and would fail
        // the scan too), so no single gate's removal flips it. It documents
        // that a season-style numeric title survives the decode rule.
        let parsed = ParsedListId.parse("20242025 <20242025.example.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "20242025.example.com", title: "20242025")
        )
    }

    func testParse_longBase64AlphabetHumanWordPhraseIsPreserved() {
        // HONEST SCOPE: "Newsletters" pads to valid base64 and decodes to
        // eight bytes, passing every length gate, but its decode carries only
        // one digit byte — so the byte scan rejects it first and the digit
        // threshold would too, and no single gate's removal flips it. It
        // documents that a long brand word survives the decode rule; the
        // scan-only pin is the "MTIzNDU2N3g=" test below.
        let parsed = ParsedListId.parse("Newsletters <newsletters.example.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "newsletters.example.com", title: "Newsletters")
        )
    }

    func testParse_base64OfDigitHeavyTokenWithForeignByteIsPreserved() {
        // Revert-check: the digit/separator byte scan in
        // ParsedListId.isBase64EncodedNumericIdentifier — "MTIzNDU2N3g="
        // decodes to "1234567x" (eight bytes, seven digits), so the digit
        // threshold alone would flag it; only the scan's rejection of the
        // trailing non-digit, non-separator byte keeps a decode that is not
        // purely digit-runs-and-separators from being treated as an encoded
        // numeric identifier.
        let parsed = ParsedListId.parse("MTIzNDU2N3g= <mtizndu2n3g=.example.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "mtizndu2n3g=.example.com", title: "MTIzNDU2N3g=")
        )
    }

    func testParse_base64OfDigitSparseTokenPhraseIsPreserved() {
        // Revert-check: the digitCount >= 6 threshold in
        // ParsedListId.isBase64EncodedNumericIdentifier — "MS0yLTMtNC01"
        // decodes to "1-2-3-4-5" (nine bytes, all digits-and-dashes, five
        // digits), so only the threshold keeps a digit-sparse decode from
        // being flagged as an encoded numeric identifier.
        let parsed = ParsedListId.parse("MS0yLTMtNC01 <ms0yltmtnc01.example.com>")

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "ms0yltmtnc01.example.com", title: "MS0yLTMtNC01")
        )
    }

    func testParse_bareTokenPhraseInKnownProviderShapeIsNotUsedAsDisplayTitle() {
        // Revert-check: Brevo's exact provider suffix allowlist. This token is
        // short and digit-light, so only the verified provider shape marks it
        // as machine metadata.
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

    func testParse_singleWordHumanPhraseBeforeUnverifiedListIdLabelIsPreserved() {
        // A literal `list-id` label elsewhere in an unrecognized domain does
        // not prove that a matching one-word phrase is provider metadata.
        let parsed = ParsedListId.parse(
            "Announcements <announcements.community.list-id.example.org>"
        )

        XCTAssertEqual(
            parsed,
            ParsedListId(
                id: "announcements.community.list-id.example.org",
                title: "Announcements"
            )
        )
    }

    func testParse_singleWordHumanPhraseAdjacentToUnverifiedListIdLabelIsPreserved() {
        // Adjacency to `list-id` is not enough; only a verified provider
        // suffix may supply the structural machine-token signal.
        let parsed = ParsedListId.parse(
            "Announcements <announcements.list-id.example.org>"
        )

        XCTAssertEqual(
            parsed,
            ParsedListId(id: "announcements.list-id.example.org", title: "Announcements")
        )
    }

    func testParse_multiWordPhraseBeforeListIdLabelIsPreserved() {
        // Revert-check: the titleIsBareToken gate — a human phrase survives
        // even when its compressed label key passes an identifier rule.
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
        // title; combined with a provider rule it could flag any phrase whose
        // whole key lands in the suffix allowlist.
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
