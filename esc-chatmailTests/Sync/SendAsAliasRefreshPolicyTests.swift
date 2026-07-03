import XCTest
@testable import esc_chatmail

final class SendAsAliasRefreshPolicyTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SendAsAliasRefreshPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makePolicy(now: Date) -> SendAsAliasRefreshPolicy {
        SendAsAliasRefreshPolicy(userDefaults: defaults, now: { now })
    }

    func testShouldRefresh_whenNeverRefreshed() {
        let policy = makePolicy(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(policy.shouldRefresh(accountEmail: "user@example.com"))
    }

    func testSkipsInsideTTL_andRefreshesAfterTTL() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        makePolicy(now: start).recordSuccessfulRefresh(accountEmail: "user@example.com")

        let insideTTL = start.addingTimeInterval(SendAsAliasRefreshPolicy.ttl - 1)
        XCTAssertFalse(makePolicy(now: insideTTL).shouldRefresh(accountEmail: "user@example.com"))

        let atTTL = start.addingTimeInterval(SendAsAliasRefreshPolicy.ttl)
        XCTAssertTrue(makePolicy(now: atTTL).shouldRefresh(accountEmail: "user@example.com"))
    }

    func testTimestampIsKeyedPerAccount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        makePolicy(now: now).recordSuccessfulRefresh(accountEmail: "first@example.com")

        // A different account (e.g. after sign-out/sign-in) must not inherit
        // the previous account's timestamp.
        XCTAssertTrue(makePolicy(now: now).shouldRefresh(accountEmail: "second@example.com"))
        XCTAssertFalse(makePolicy(now: now).shouldRefresh(accountEmail: "first@example.com"))
    }

    func testAccountKeyIsNormalized() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        makePolicy(now: now).recordSuccessfulRefresh(accountEmail: "User.Name@GMail.com")
        XCTAssertFalse(makePolicy(now: now).shouldRefresh(accountEmail: "username@gmail.com"))
    }
}
