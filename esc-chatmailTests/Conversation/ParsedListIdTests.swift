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
