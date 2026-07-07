import XCTest
import Contacts
import UIKit
@testable import esc_chatmail

@MainActor
final class ContactsAuthorizationCoordinatorTests: XCTestCase {
    func testStatusChangeInvalidatesCachesAndBroadcastsOnce() async {
        let status = StatusBox(.notDetermined)
        let invalidations = InvocationCounter()
        let broadcasts = InvocationCounter()
        let coordinator = makeCoordinator(
            status: status,
            invalidations: invalidations,
            broadcasts: broadcasts
        )

        // Same status as construction time: nothing to do.
        await coordinator.handlePotentialStatusChange()
        XCTAssertEqual(invalidations.count, 0)
        XCTAssertEqual(broadcasts.count, 0)

        status.set(.authorized)
        await coordinator.handlePotentialStatusChange()
        XCTAssertEqual(invalidations.count, 1)
        XCTAssertEqual(broadcasts.count, 1)

        // Unchanged status must not re-invalidate.
        await coordinator.handlePotentialStatusChange()
        XCTAssertEqual(invalidations.count, 1)
        XCTAssertEqual(broadcasts.count, 1)
    }

    func testForegroundNotificationTriggersStatusCheck() async {
        let center = NotificationCenter()
        let status = StatusBox(.notDetermined)
        let broadcasts = InvocationCounter()
        let coordinator = makeCoordinator(
            notificationCenter: center,
            status: status,
            broadcasts: broadcasts
        )
        // Grant happens outside the app (Settings), observed on next foreground.
        status.set(.authorized)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await waitUntil { broadcasts.count == 1 }
        _ = coordinator
    }

    func testContactStoreChangeNotificationTriggersStatusCheck() async {
        let center = NotificationCenter()
        let status = StatusBox(.notDetermined)
        let broadcasts = InvocationCounter()
        let coordinator = makeCoordinator(
            notificationCenter: center,
            status: status,
            broadcasts: broadcasts
        )
        status.set(.authorized)

        center.post(name: .CNContactStoreDidChange, object: nil)

        await waitUntil { broadcasts.count == 1 }
        _ = coordinator
    }

    func testRequestAccessOnFirstAuthenticatedLaunchRequestsOncePerLaunch() async {
        let status = StatusBox(.notDetermined)
        let requests = InvocationCounter()
        let broadcasts = InvocationCounter()
        let coordinator = makeCoordinator(
            status: status,
            requests: requests,
            broadcasts: broadcasts
        )

        coordinator.requestAccessOnFirstAuthenticatedLaunchIfNeeded()
        coordinator.requestAccessOnFirstAuthenticatedLaunchIfNeeded()

        await waitUntil { requests.count == 1 }
        // The grant flows through the same status-change handling as any other path.
        await waitUntil { broadcasts.count == 1 }
        XCTAssertEqual(requests.count, 1)
    }

    func testRequestAccessSkippedWhenStatusAlreadyDetermined() async {
        let status = StatusBox(.authorized)
        let requests = InvocationCounter()
        let coordinator = makeCoordinator(status: status, requests: requests)

        coordinator.requestAccessOnFirstAuthenticatedLaunchIfNeeded()

        // Give any (incorrect) request task a beat to run before asserting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(requests.count, 0)
        _ = coordinator
    }

    // MARK: - Fixture

    private func makeCoordinator(
        notificationCenter: NotificationCenter = NotificationCenter(),
        status: StatusBox,
        requests: InvocationCounter = InvocationCounter(),
        invalidations: InvocationCounter = InvocationCounter(),
        broadcasts: InvocationCounter = InvocationCounter()
    ) -> ContactsAuthorizationCoordinator {
        ContactsAuthorizationCoordinator(
            notificationCenter: notificationCenter,
            authorizationStatusProvider: { status.status },
            requestAccess: {
                requests.increment()
                status.set(.authorized)
                return .authorized
            },
            invalidateResolutionCaches: { invalidations.increment() },
            broadcastDisplayInfoChange: { broadcasts.increment() }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: CNAuthorizationStatus

    init(_ status: CNAuthorizationStatus) {
        _status = status
    }

    var status: CNAuthorizationStatus {
        lock.withLock { _status }
    }

    func set(_ status: CNAuthorizationStatus) {
        lock.withLock { _status = status }
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.withLock { _count }
    }

    func increment() {
        lock.withLock { _count += 1 }
    }
}
