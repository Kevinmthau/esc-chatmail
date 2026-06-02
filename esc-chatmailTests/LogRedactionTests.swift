import XCTest
@testable import esc_chatmail

final class LogRedactionTests: XCTestCase {

    // MARK: - redact(email:)

    func testRedactEmail_standard_keepsFirstCharAndDomain() {
        XCTAssertEqual(Log.redact(email: "jane.doe@example.com"), "j***@example.com")
    }

    func testRedactEmail_singleCharLocal_masksEntireLocalPart() {
        XCTAssertEqual(Log.redact(email: "a@example.com"), "***@example.com")
    }

    func testRedactEmail_emptyLocalPart_masksLocalPart() {
        XCTAssertEqual(Log.redact(email: "@example.com"), "***@example.com")
    }

    func testRedactEmail_doesNotLeakLocalPartBeyondFirstChar() {
        let redacted = Log.redact(email: "supersecretuser@example.com")
        XCTAssertFalse(redacted.contains("supersecretuser"))
        XCTAssertFalse(redacted.contains("upersecret"))
        XCTAssertTrue(redacted.hasPrefix("s***@"))
    }

    func testRedactEmail_nonEmailValue_isFullyMasked() {
        XCTAssertEqual(Log.redact(email: "not-an-email"), "<redacted>")
    }

    func testRedactEmail_nilAndEmpty_returnNonePlaceholder() {
        XCTAssertEqual(Log.redact(email: nil), "<none>")
        XCTAssertEqual(Log.redact(email: ""), "<none>")
    }

    // MARK: - redact(address:)

    func testRedactAddress_headerWithDisplayName_dropsNameAndRedactsEmail() {
        let redacted = Log.redact(address: "Jane Doe <jane@example.com>")
        XCTAssertEqual(redacted, "j***@example.com")
        XCTAssertFalse(redacted.contains("Jane"))
        XCTAssertFalse(redacted.contains("Doe"))
    }

    func testRedactAddress_bareEmail_isRedacted() {
        XCTAssertEqual(Log.redact(address: "jane@example.com"), "j***@example.com")
    }

    func testRedactAddress_malformedAngleBracketHeader_isFullyMasked() {
        let redacted = Log.redact(address: "Jane <jane@example.com (Jane Doe)>")

        XCTAssertEqual(redacted, "<redacted>")
        XCTAssertFalse(redacted.contains("Jane"))
        XCTAssertFalse(redacted.contains("Doe"))
        XCTAssertFalse(redacted.contains("example.com"))
    }

    func testRedactAddress_noParseableEmail_isFullyMasked() {
        XCTAssertEqual(Log.redact(address: "unknown"), "<redacted>")
    }

    func testRedactAddress_nilAndEmpty_returnNonePlaceholder() {
        XCTAssertEqual(Log.redact(address: nil), "<none>")
        XCTAssertEqual(Log.redact(address: ""), "<none>")
    }

    // MARK: - redact(url:)

    func testRedactURL_stripsPathQueryAndFragment() {
        let url = URL(string: "https://example.com/reset?token=secret#frag")!
        let redacted = Log.redact(url: url)
        XCTAssertEqual(redacted, "https://example.com/...")
        XCTAssertFalse(redacted.contains("token"))
        XCTAssertFalse(redacted.contains("secret"))
    }

    func testRedactURL_hostOnly_keepsSchemeAndHost() {
        XCTAssertEqual(Log.redact(url: URL(string: "https://example.com")!), "https://example.com")
    }

    func testRedactURL_trailingSlashOnly_treatedAsNoDetail() {
        XCTAssertEqual(Log.redact(url: URL(string: "https://example.com/")!), "https://example.com")
    }

    func testRedactURL_queryWithoutPath_marksDetail() {
        XCTAssertEqual(Log.redact(url: URL(string: "https://example.com?token=secret")!), "https://example.com/...")
    }

    func testRedactURL_fileURL_dropsPathThatMayEncodePII() {
        let url = URL(string: "file:///var/mobile/Containers/Avatars/amFuZUBleGFtcGxlLmNvbQ.jpg")!
        let redacted = Log.redact(url: url)
        XCTAssertEqual(redacted, "file:...")
        XCTAssertFalse(redacted.contains("Avatars"))
        XCTAssertFalse(redacted.contains("amFuZUB"))
    }

    func testRedactURL_nilURL_returnsNonePlaceholder() {
        let url: URL? = nil
        XCTAssertEqual(Log.redact(url: url), "<none>")
    }

    // MARK: - redact(url:) String overload

    func testRedactURLString_validURL_isRedacted() {
        XCTAssertEqual(Log.redact(url: "https://example.com/path?q=1"), "https://example.com/...")
    }

    func testRedactURLString_nilAndEmpty_returnNonePlaceholder() {
        XCTAssertEqual(Log.redact(url: String?.none), "<none>")
        XCTAssertEqual(Log.redact(url: ""), "<none>")
    }
}
