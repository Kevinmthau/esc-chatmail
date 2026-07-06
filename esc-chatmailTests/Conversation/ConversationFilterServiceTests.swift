import XCTest
import Contacts
@testable import esc_chatmail

@MainActor
final class ConversationFilterServiceTests: XCTestCase {
    func testContactStoreChangeDuringLoad_discardsStaleResultAndRunsFollowUpRefresh() async {
        let contactsService = ContactsService()
        contactsService.authorizationStatus = .authorized

        let notificationCenter = NotificationCenter()
        let firstLoadCanFinish = AsyncGate()
        let secondLoadCanFinish = AsyncGate()
        let firstLoadStarted = expectation(description: "first load started")
        let secondLoadStarted = expectation(description: "second load started")
        let finalCacheUpdated = expectation(description: "final cache updated")

        var loadCalls = 0
        let service = ConversationFilterService(
            contactsService: contactsService,
            notificationCenter: notificationCenter,
            contactEmailLoader: { requestAccessIfNeeded in
                XCTAssertFalse(requestAccessIfNeeded)
                loadCalls += 1

                switch loadCalls {
                case 1:
                    firstLoadStarted.fulfill()
                    await firstLoadCanFinish.wait()
                    return ["stale@example.com"]
                case 2:
                    secondLoadStarted.fulfill()
                    await secondLoadCanFinish.wait()
                    return ["fresh@example.com"]
                default:
                    XCTFail("Unexpected extra contact cache load")
                    return []
                }
            }
        )

        service.onFilterStateChange = {
            if service.contactEmailsCache == Set(["fresh@example.com"]) {
                finalCacheUpdated.fulfill()
            }
        }

        service.loadContactsCache()
        await fulfillment(of: [firstLoadStarted], timeout: 1.0)

        notificationCenter.post(name: .CNContactStoreDidChange, object: nil)
        await firstLoadCanFinish.open()

        await fulfillment(of: [secondLoadStarted], timeout: 1.0)
        XCTAssertTrue(service.contactEmailsCache.isEmpty)

        await secondLoadCanFinish.open()

        await fulfillment(of: [finalCacheUpdated], timeout: 1.0)
        XCTAssertEqual(service.contactEmailsCache, Set(["fresh@example.com"]))
        XCTAssertEqual(loadCalls, 2)
    }

    func testRepeatedContactStoreChangesDuringLoad_coalesceIntoSingleFollowUpRefresh() async {
        let contactsService = ContactsService()
        contactsService.authorizationStatus = .authorized

        let notificationCenter = NotificationCenter()
        let firstLoadCanFinish = AsyncGate()
        let secondLoadStarted = expectation(description: "second load started")
        let finalCacheUpdated = expectation(description: "final cache updated")

        var loadCalls = 0
        let service = ConversationFilterService(
            contactsService: contactsService,
            notificationCenter: notificationCenter,
            contactEmailLoader: { requestAccessIfNeeded in
                XCTAssertFalse(requestAccessIfNeeded)
                loadCalls += 1

                switch loadCalls {
                case 1:
                    await firstLoadCanFinish.wait()
                    return ["stale@example.com"]
                case 2:
                    secondLoadStarted.fulfill()
                    return ["fresh@example.com"]
                default:
                    XCTFail("Expected invalidations to coalesce into one follow-up refresh")
                    return []
                }
            }
        )

        service.onFilterStateChange = {
            if service.contactEmailsCache == Set(["fresh@example.com"]) {
                finalCacheUpdated.fulfill()
            }
        }

        service.loadContactsCache()

        notificationCenter.post(name: .CNContactStoreDidChange, object: nil)
        notificationCenter.post(name: .CNContactStoreDidChange, object: nil)
        await firstLoadCanFinish.open()

        await fulfillment(of: [secondLoadStarted, finalCacheUpdated], timeout: 1.0)
        XCTAssertEqual(service.contactEmailsCache, Set(["fresh@example.com"]))
        XCTAssertEqual(loadCalls, 2)
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}
