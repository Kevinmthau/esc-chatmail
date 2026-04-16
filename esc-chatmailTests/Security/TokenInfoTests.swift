import XCTest
@testable import esc_chatmail

final class TokenInfoTests: XCTestCase {

    // MARK: - isExpired

    func testIsExpired_futureExpirationDate_returnsFalse() {
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date().addingTimeInterval(3600),
            scope: nil
        )
        XCTAssertFalse(info.isExpired)
    }

    func testIsExpired_pastExpirationDate_returnsTrue() {
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date().addingTimeInterval(-60),
            scope: nil
        )
        XCTAssertTrue(info.isExpired)
    }

    func testIsExpired_atExactExpiration_returnsTrue() {
        // `Date() >= expirationDate` — equal counts as expired
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date().addingTimeInterval(-0.01),
            scope: nil
        )
        XCTAssertTrue(info.isExpired)
    }

    // MARK: - isExpiringSoon

    func testIsExpiringSoon_expiresWithinFiveMinutes_returnsTrue() {
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date().addingTimeInterval(60), // 1 minute
            scope: nil
        )
        XCTAssertTrue(info.isExpiringSoon)
    }

    func testIsExpiringSoon_expiresAfterSixMinutes_returnsFalse() {
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date().addingTimeInterval(360),
            scope: nil
        )
        XCTAssertFalse(info.isExpiringSoon)
    }

    func testIsExpiringSoon_alreadyExpired_returnsTrue() {
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date().addingTimeInterval(-120),
            scope: nil
        )
        XCTAssertTrue(info.isExpiringSoon)
    }

    // MARK: - Codable round-trip

    func testCodable_roundTripPreservesFields() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let info = TokenInfo(
            accessToken: "access-abc",
            refreshToken: "refresh-xyz",
            expirationDate: date,
            scope: "gmail.readonly gmail.modify"
        )

        let encoded = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TokenInfo.self, from: encoded)

        XCTAssertEqual(decoded.accessToken, "access-abc")
        XCTAssertEqual(decoded.refreshToken, "refresh-xyz")
        XCTAssertEqual(decoded.expirationDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.scope, "gmail.readonly gmail.modify")
    }

    func testCodable_roundTripWithNilRefreshToken() throws {
        let info = TokenInfo(
            accessToken: "a",
            refreshToken: nil,
            expirationDate: Date(),
            scope: nil
        )

        let encoded = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TokenInfo.self, from: encoded)

        XCTAssertNil(decoded.refreshToken)
        XCTAssertNil(decoded.scope)
    }
}
