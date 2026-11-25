import XCTest
@testable import esc_chatmail

/// `ServerClockEstimate`: Gmail's time carried forward on a monotonic clock, and a "now"
/// that is never later than the device's.
final class ServerClockEstimateTests: XCTestCase {
    /// A wall clock and a monotonic clock the test moves by hand.
    /// `@unchecked Sendable`: only the test's own thread touches it.
    private final class Clocks: @unchecked Sendable {
        var device = Date(timeIntervalSince1970: 1_800_000_000)
        var elapsed: Duration = .zero
    }

    private func makeEstimate(_ clocks: Clocks) -> ServerClockEstimate {
        ServerClockEstimate(deviceNow: { clocks.device }, elapsed: { clocks.elapsed })
    }

    func testConservativeNow_withNoResponseRecorded_isTheDevicesTime() {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)

        XCTAssertNil(estimate.estimatedServerNow)
        XCTAssertEqual(estimate.conservativeNow(), clocks.device)
    }

    func testConservativeNow_deviceAheadOfGmail_isGmailsTimeCarriedForward() throws {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)
        let serverDate = try XCTUnwrap(ServerClockEstimate.parseHTTPDate("Fri, 15 Jan 2027 06:00:00 GMT"))
        clocks.device = serverDate.addingTimeInterval(2 * 3600)

        estimate.record(serverDate: serverDate)
        clocks.elapsed = .seconds(90)
        clocks.device = clocks.device.addingTimeInterval(90)

        XCTAssertEqual(estimate.conservativeNow(), serverDate.addingTimeInterval(90))
    }

    /// The device's time is the later bound: a server estimate ahead of it never moves
    /// "now" later, so no floor drawn from it can be later than before.
    func testConservativeNow_deviceBehindGmail_isTheDevicesTime() {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)

        estimate.record(serverDate: clocks.device.addingTimeInterval(3600))

        XCTAssertEqual(estimate.conservativeNow(), clocks.device)
    }

    /// A change of the wall clock after the response does not move the estimate.
    func testEstimate_wallClockChangedAfterTheResponse_isUnmoved() {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)
        let serverDate = clocks.device

        estimate.record(serverDate: serverDate)
        clocks.device = clocks.device.addingTimeInterval(86_400)

        XCTAssertEqual(estimate.estimatedServerNow, serverDate)
        XCTAssertEqual(estimate.conservativeNow(), serverDate)
    }

    /// One broken `Date` header must not move every floor arbitrarily far back.
    ///
    /// Revert-check: the `maximumPlausibleSkew` guard in `ServerClockEstimate.record`.
    func testRecord_dateFartherFromTheDeviceThanPlausible_isNotRecorded() {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)

        estimate.record(serverDate: clocks.device.addingTimeInterval(-ServerClockEstimate.maximumPlausibleSkew - 1))
        estimate.record(serverDate: Date(timeIntervalSince1970: 0))

        XCTAssertNil(estimate.estimatedServerNow)
        XCTAssertEqual(estimate.conservativeNow(), clocks.device)
        XCTAssertEqual(estimate.deviceClockLead(), 0)
    }

    func testDeviceClockLead_isHowFarTheDeviceIsAhead_andNeverNegative() {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)
        XCTAssertEqual(estimate.deviceClockLead(), 0)

        estimate.record(serverDate: clocks.device.addingTimeInterval(-7200))
        XCTAssertEqual(estimate.deviceClockLead(), 7200, accuracy: 0.001)

        estimate.record(serverDate: clocks.device.addingTimeInterval(600))
        XCTAssertEqual(estimate.deviceClockLead(), 0)
    }

    func testRecordResponseDate_missingOrMalformedHeader_recordsNothing() {
        let clocks = Clocks()
        let estimate = makeEstimate(clocks)

        estimate.recordResponseDate(httpDateHeader: nil)
        estimate.recordResponseDate(httpDateHeader: "")
        estimate.recordResponseDate(httpDateHeader: "yesterday")
        estimate.recordResponseDate(httpDateHeader: "2027-01-15T06:00:00Z")

        XCTAssertNil(estimate.estimatedServerNow)
    }

    func testParseHTTPDate_readsIMFFixdate() {
        XCTAssertEqual(
            ServerClockEstimate.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT")?.timeIntervalSince1970,
            784_111_777
        )
    }
}
