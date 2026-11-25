import XCTest
@testable import esc_chatmail

/// The real `GmailAPIClient` through `StubURLProtocol`: a read's 2xx `Date` header feeds
/// the client's `ServerClockEstimate`, and messages.send never touches it.
final class GmailAPIClientServerDateTests: XCTestCase {
    private var tokenManager: MockTokenManager!
    private var serverClock: ServerClockEstimate!
    private var client: GmailAPIClient!

    private static let profileBody = Data(
        #"{"emailAddress":"me@example.com","messagesTotal":1,"threadsTotal":1,"historyId":"42"}"#.utf8
    )
    private static let sendBody = Data(#"{"id":"sent-1","threadId":"thread-1"}"#.utf8)

    /// A date near the device's: one farther than `maximumPlausibleSkew` is not recorded.
    private static let serverDateHeader: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date().addingTimeInterval(-3600))
    }()

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokenManager = MockTokenManager()
        serverClock = ServerClockEstimate()
        client = GmailAPIClient(
            tokenManager: tokenManager,
            retryStrategy: NetworkRetryStrategy(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.02),
            session: StubURLProtocol.makeSession(),
            serverClock: serverClock
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        serverClock = nil
        tokenManager = nil
        super.tearDown()
    }

    /// Revert-check: the `serverClock.recordResponseDate` call in
    /// `GmailAPIClient.performRetryingRequest`'s 2xx branch.
    func testRead_2xxWithDateHeader_recordsGmailsTime() async throws {
        StubURLProtocol.script = [
            .dataWithHeaders(200, Self.profileBody, ["Date": Self.serverDateHeader])
        ]

        _ = try await client.getProfile()

        let estimate = try XCTUnwrap(serverClock.estimatedServerNow)
        let serverDate = try XCTUnwrap(ServerClockEstimate.parseHTTPDate(Self.serverDateHeader))
        XCTAssertEqual(estimate.timeIntervalSince(serverDate), 0, accuracy: 60)
    }

    func testRead_non2xx_recordsNothing() async {
        StubURLProtocol.script = [
            .dataWithHeaders(404, Data(), ["Date": Self.serverDateHeader])
        ]

        _ = try? await client.getProfile()

        XCTAssertNil(serverClock.estimatedServerNow)
    }

    /// messages.send is non-idempotent: nothing on its path may read a header for this,
    /// and a malformed one changes nothing about its outcome.
    ///
    /// Revert-check: the `behavior.allowsRetransmission` condition in front of
    /// `serverClock.recordResponseDate`: the valid header is then recorded.
    /// HONEST SCOPE: only that pass of the loop fails on the revert; the malformed and empty
    /// ones pin that a send's outcome does not depend on the header, and would pass either
    /// way.
    func testSend_dateHeaderValidOrMalformed_recordsNothingAndSucceeds() async throws {
        for header in [Self.serverDateHeader, "not a date", ""] {
            StubURLProtocol.reset()
            StubURLProtocol.script = [.dataWithHeaders(200, Self.sendBody, ["Date": header])]

            let response = try await client.sendMessage(rawMessage: "raw")

            XCTAssertEqual(response.id, "sent-1", "header \(header)")
            XCTAssertEqual(StubURLProtocol.requestCount, 1, "header \(header)")
            XCTAssertNil(serverClock.estimatedServerNow, "header \(header)")
        }
    }
}
