import XCTest
#if os(iOS)
import UIKit
#endif
@testable import esc_chatmail

/// The lease a foreground-entry sync run holds (`SyncRunBackgroundLease`):
/// one grant, ended once, and at expiration the run is cancelled and the grant
/// ended before the handler returns.
///
/// HONEST SCOPE: the manager is a spy. When UIKit expires a grant, and
/// whether it refuses one, is not observable on a simulator.
@MainActor
final class SyncRunBackgroundLeaseTests: XCTestCase {

    // Revert-check (combined): the `guard !hasEnded` in
    // `SyncRunBackgroundLease.end` together with its `identifier = .invalid`
    // (the second end reaches the manager again).
    // HONEST SCOPE: each of the two alone keeps `end` idempotent, so no
    // single-line revert fails this test; it pins the pair.
    func testEnd_afterBegin_endsTheGrantOnce() {
        let manager = SyncRunBackgroundTaskManagerSpy()
        let lease = SyncRunBackgroundLease(manager: manager)

        lease.begin(onExpiration: { XCTFail("Not expired") })
        lease.end()
        lease.end()

        XCTAssertEqual(manager.beginCount, 1)
        XCTAssertEqual(manager.endedIdentifiers, [manager.grantedIdentifier])
    }

    /// UIKit expects the grant ended before its expiration handler returns:
    /// one left running past it is a watchdog kill. The run is cancelled
    /// first, and nothing is awaited.
    ///
    /// Revert-check: the `self.end()` in the expiration handler that
    /// `SyncRunBackgroundLease.begin` gives the manager (the grant is still
    /// held when the handler returns).
    func testExpiration_cancelsTheRunThenEndsTheGrantBeforeReturning() {
        let manager = SyncRunBackgroundTaskManagerSpy()
        let lease = SyncRunBackgroundLease(manager: manager)
        let endsSeenByCancel = ExpirationRecord()
        lease.begin(onExpiration: { endsSeenByCancel.value = manager.endCount })

        manager.expire()

        XCTAssertEqual(endsSeenByCancel.value, 0, "The run is cancelled before the grant ends")
        XCTAssertEqual(manager.endedIdentifiers, [manager.grantedIdentifier], "Ended inside the handler")
        lease.end()
        manager.expire()
        XCTAssertEqual(manager.endCount, 1, "Neither the chain's end nor a second expiration ends it again")
    }

    // Revert-check: the `if hasEnded` branch after `manager.begin` in
    // `SyncRunBackgroundLease.begin` (a grant that expired inside `begin`
    // returns an identifier nobody ends).
    func testExpiration_insideBegin_cancelsTheRunAndEndsTheGrant() {
        let manager = SyncRunBackgroundTaskManagerSpy()
        manager.expiresDuringBegin = true
        let lease = SyncRunBackgroundLease(manager: manager)
        let cancelled = ExpirationRecord()

        lease.begin(onExpiration: { cancelled.value = 1 })

        XCTAssertEqual(cancelled.value, 1)
        XCTAssertEqual(manager.endedIdentifiers, [manager.grantedIdentifier])
        lease.end()
        XCTAssertEqual(manager.endCount, 1)
    }

    /// A grant the platform refuses cancels nothing: the run goes on as it did
    /// before the lease, and there is nothing to end.
    ///
    /// Revert-check: the `guard identifier != .invalid` in
    /// `SyncRunBackgroundLease.end` (the refused identifier is ended).
    func testRefusedGrant_cancelsNothingAndEndsNothing() {
        let manager = SyncRunBackgroundTaskManagerSpy()
        manager.identifierToGrant = .invalid
        let lease = SyncRunBackgroundLease(manager: manager)

        lease.begin(onExpiration: { XCTFail("A refused grant is no expiration") })
        lease.end()

        XCTAssertEqual(manager.beginCount, 1)
        XCTAssertEqual(manager.endCount, 0)
    }

    // Revert-check: the `!hasEnded` in `SyncRunBackgroundLease.begin`'s guard
    // (a chain that has already ended takes a grant nobody ends).
    func testBegin_afterEnd_takesNoGrant() {
        let manager = SyncRunBackgroundTaskManagerSpy()
        let lease = SyncRunBackgroundLease(manager: manager)

        lease.end()
        lease.begin(onExpiration: { XCTFail("Never begun") })

        XCTAssertEqual(manager.beginCount, 0)
        XCTAssertEqual(manager.endCount, 0)
    }
}

/// What an expiration handler saw, kept in a reference because the handler is
/// `@Sendable` and cannot write a captured variable.
@MainActor
private final class ExpirationRecord {
    var value: Int?
}
