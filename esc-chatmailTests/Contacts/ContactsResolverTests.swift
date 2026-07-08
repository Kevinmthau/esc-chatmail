import XCTest
import Contacts
@testable import esc_chatmail

final class ContactsResolverTests: XCTestCase {
    func testCreateMatchUsesOrganizationNameWhenFullNameIsUnavailable() async {
        let contact = CNMutableContact()
        contact.organizationName = "Gables Station"
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "announcements@gables.example" as NSString)
        ]

        let match = await ContactsResolver.shared.createMatch(
            from: contact.copy() as! CNContact,
            email: "announcements@gables.example"
        )

        XCTAssertEqual(match.displayName, "Gables Station")
    }

    func testLookupAtNotDeterminedReturnsNilWithoutPresentingThePrompt() async {
        let authState = AuthorizationStateBox(.notDetermined)
        let resolver = ContactsResolver(
            authorizationStatusProvider: { authState.status },
            accessRequester: {
                authState.recordRequest()
                return true
            }
        )

        let match = await resolver.lookup(email: "someone@example.com")

        XCTAssertNil(match)
        XCTAssertEqual(authState.requestCount, 0)
    }

    func testEnsureAuthorizationThrowsNotDeterminedInsteadOfRequesting() async {
        let authState = AuthorizationStateBox(.notDetermined)
        let resolver = ContactsResolver(
            authorizationStatusProvider: { authState.status },
            accessRequester: {
                authState.recordRequest()
                return true
            }
        )

        do {
            try await resolver.ensureAuthorization()
            XCTFail("Expected accessNotDetermined")
        } catch {
            guard case ContactsError.accessNotDetermined = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(authState.requestCount, 0)
    }

    func testRequestAccessIfNeededDeduplicatesConcurrentCallers() async {
        let authState = AuthorizationStateBox(.notDetermined)
        let resolver = ContactsResolver(
            authorizationStatusProvider: { authState.status },
            accessRequester: {
                authState.recordRequest()
                // Hold the request open long enough for the other callers to pile in.
                try? await Task.sleep(nanoseconds: 100_000_000)
                authState.set(.authorized)
                return true
            }
        )

        let statuses = await withTaskGroup(of: CNAuthorizationStatus.self) { group in
            for _ in 0..<5 {
                group.addTask { await resolver.requestAccessIfNeeded() }
            }
            return await group.reduce(into: [CNAuthorizationStatus]()) { $0.append($1) }
        }

        XCTAssertEqual(authState.requestCount, 1)
        XCTAssertEqual(statuses, Array(repeating: .authorized, count: 5))
    }

    func testRequestAccessIfNeededSkipsRequestWhenAlreadyDetermined() async {
        let authState = AuthorizationStateBox(.denied)
        let resolver = ContactsResolver(
            authorizationStatusProvider: { authState.status },
            accessRequester: {
                authState.recordRequest()
                return true
            }
        )

        let status = await resolver.requestAccessIfNeeded()

        XCTAssertEqual(status, .denied)
        XCTAssertEqual(authState.requestCount, 0)
    }
}

/// Synchronous authorization-state holder for the resolver's testing seams
/// (the status provider is a sync closure, so actor state can't back it).
private final class AuthorizationStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: CNAuthorizationStatus
    private var _requestCount = 0

    init(_ status: CNAuthorizationStatus) {
        _status = status
    }

    var status: CNAuthorizationStatus {
        lock.withLock { _status }
    }

    var requestCount: Int {
        lock.withLock { _requestCount }
    }

    func set(_ status: CNAuthorizationStatus) {
        lock.withLock { _status = status }
    }

    func recordRequest() {
        lock.withLock { _requestCount += 1 }
    }
}
