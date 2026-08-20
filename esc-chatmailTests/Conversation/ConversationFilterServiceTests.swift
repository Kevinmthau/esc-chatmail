import XCTest
import Contacts
@testable import esc_chatmail

@MainActor
final class ConversationFilterServiceTests: XCTestCase {
    // Revert-check: finishContactsLoad's pendingContactsCacheInvalidation
    // branch (fed by handleContactStoreDidChange's mid-load latch) — without
    // it the stale first result would publish into contactEmailsCache and no
    // follow-up load would run, failing the loadCalls == 2 assertion.
    func testContactStoreChangeDuringLoad_discardsStaleResultAndRunsFollowUpRefresh() async {
        let notificationCenter = NotificationCenter()
        let firstLoadCanFinish = AsyncGate()
        let secondLoadCanFinish = AsyncGate()
        let firstLoadStarted = expectation(description: "first load started")
        let secondLoadStarted = expectation(description: "second load started")
        let finalCacheUpdated = expectation(description: "final cache updated")

        var loadCalls = 0
        let service = ConversationFilterService(
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
            },
            notificationCenter: notificationCenter
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

    // Revert-check: handleContactStoreDidChange's mid-load
    // pendingContactsCacheInvalidation latch — repeated notifications during
    // one load set the same Bool, so finishContactsLoad runs exactly one
    // follow-up refresh; a per-notification reload would trip the
    // loadCalls-limiting XCTFail in the loader.
    func testRepeatedContactStoreChangesDuringLoad_coalesceIntoSingleFollowUpRefresh() async {
        let notificationCenter = NotificationCenter()
        let firstLoadCanFinish = AsyncGate()
        let secondLoadStarted = expectation(description: "second load started")
        let finalCacheUpdated = expectation(description: "final cache updated")

        var loadCalls = 0
        let service = ConversationFilterService(
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
            },
            notificationCenter: notificationCenter
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

    // Revert-check: the loadContactsCache(requestAccessIfNeeded: true) trigger
    // in ConversationFilterService.currentFilter's didSet — removing the
    // trigger (or downgrading its requestAccessIfNeeded flag to false) fails
    // the recorded-flags assertion below.
    func testCurrentFilter_switchToContactsWithColdCache_requestsAccessAndPopulatesCache() async {
        let notificationCenter = NotificationCenter()
        let cachePopulated = expectation(description: "contacts cache populated")

        var recordedAccessRequests: [Bool] = []
        let service = ConversationFilterService(
            contactEmailLoader: { requestAccessIfNeeded in
                recordedAccessRequests.append(requestAccessIfNeeded)
                return ["contact@example.com"]
            },
            notificationCenter: notificationCenter
        )
        service.onFilterStateChange = {
            if service.contactEmailsCache == Set(["contact@example.com"]) {
                cachePopulated.fulfill()
            }
        }

        service.currentFilter = .contacts

        await fulfillment(of: [cachePopulated], timeout: 1.0)
        XCTAssertEqual(recordedAccessRequests, [true])
        XCTAssertEqual(service.contactEmailsCache, Set(["contact@example.com"]))
    }

    // Revert-check: the hasLoadedContactsCache clause in
    // ConversationFilterService.loadContactsCache's entry guard (F12) —
    // reverting the guard to !isLoadingContactsCache alone makes the
    // requestAccessIfNeeded: false call below start a load, so the recorded
    // flags become [true, false] and the final assertion fails.
    func testLoadContactsCache_warmCache_skipsNonAccessRequestingReload() async {
        let notificationCenter = NotificationCenter()
        let firstCachePopulated = expectation(description: "first load populated the cache")
        let reloadCachePopulated = expectation(description: "access-requesting reload populated the cache")

        var recordedAccessRequests: [Bool] = []
        let service = ConversationFilterService(
            contactEmailLoader: { requestAccessIfNeeded in
                recordedAccessRequests.append(requestAccessIfNeeded)
                return recordedAccessRequests.count == 1
                    ? ["first@example.com"]
                    : ["reloaded@example.com"]
            },
            notificationCenter: notificationCenter
        )
        service.onFilterStateChange = {
            if service.contactEmailsCache == Set(["first@example.com"]) {
                firstCachePopulated.fulfill()
            }
            if service.contactEmailsCache == Set(["reloaded@example.com"]) {
                reloadCachePopulated.fulfill()
            }
        }

        service.loadContactsCache(requestAccessIfNeeded: true)
        await fulfillment(of: [firstCachePopulated], timeout: 1.0)

        // Warm cache: this call must return without invoking the loader…
        service.loadContactsCache(requestAccessIfNeeded: false)
        // …while an access-requesting call still reloads. It doubles as the
        // ordering probe: had the skipped call above started a load, this one
        // would have been rejected as concurrent by the entry guard and the
        // recorded flags could not read [true, true].
        service.loadContactsCache(requestAccessIfNeeded: true)

        await fulfillment(of: [reloadCachePopulated], timeout: 1.0)
        XCTAssertEqual(recordedAccessRequests, [true, true])
        XCTAssertEqual(service.contactEmailsCache, Set(["reloaded@example.com"]))
    }

    // Revert-check: the hasLoadedContactsCache = false reset in
    // ConversationFilterService.handleContactStoreDidChange — without it the
    // warm-cache guard (F12) would skip the post-notification reload and this
    // test would time out waiting for the refreshed cache.
    func testLoadContactsCache_contactStoreChangeAfterWarmCache_reloadsCache() async {
        let notificationCenter = NotificationCenter()
        let firstCachePopulated = expectation(description: "first load populated the cache")
        let refreshedCachePopulated = expectation(description: "post-notification reload populated the cache")

        var loadCalls = 0
        let service = ConversationFilterService(
            contactEmailLoader: { _ in
                loadCalls += 1
                return loadCalls == 1
                    ? ["first@example.com"]
                    : ["refreshed@example.com"]
            },
            notificationCenter: notificationCenter
        )
        service.onFilterStateChange = {
            if service.contactEmailsCache == Set(["first@example.com"]) {
                firstCachePopulated.fulfill()
            }
            if service.contactEmailsCache == Set(["refreshed@example.com"]) {
                refreshedCachePopulated.fulfill()
            }
        }

        service.loadContactsCache()
        await fulfillment(of: [firstCachePopulated], timeout: 1.0)

        notificationCenter.post(name: .CNContactStoreDidChange, object: nil)

        await fulfillment(of: [refreshedCachePopulated], timeout: 1.0)
        XCTAssertEqual(loadCalls, 2)
        XCTAssertEqual(service.contactEmailsCache, Set(["refreshed@example.com"]))
    }

    // Revert-check: the isLoadingContactsCache = false reset in
    // ConversationFilterService.cancelTasks() — without it a cancelled
    // in-flight load latches the entry guard closed and the follow-up
    // loadContactsCache() here never invokes the loader, timing out the test.
    func testCancelTasks_midLoad_leavesSubsequentLoadAdmissible() async {
        let notificationCenter = NotificationCenter()
        let firstLoadStarted = expectation(description: "first load started")
        let firstLoadCanFinish = AsyncGate()
        let secondCachePopulated = expectation(description: "second load populated the cache")

        var loadCalls = 0
        let service = ConversationFilterService(
            contactEmailLoader: { _ in
                loadCalls += 1
                if loadCalls == 1 {
                    firstLoadStarted.fulfill()
                    await firstLoadCanFinish.wait()
                    return ["stale@example.com"]
                }
                return ["fresh@example.com"]
            },
            notificationCenter: notificationCenter
        )
        service.onFilterStateChange = {
            if service.contactEmailsCache == Set(["fresh@example.com"]) {
                secondCachePopulated.fulfill()
            }
        }

        service.loadContactsCache()
        await fulfillment(of: [firstLoadStarted], timeout: 1.0)

        service.cancelTasks()
        await firstLoadCanFinish.open()

        service.loadContactsCache()

        await fulfillment(of: [secondCachePopulated], timeout: 1.0)
        XCTAssertEqual(loadCalls, 2)
        XCTAssertEqual(service.contactEmailsCache, Set(["fresh@example.com"]))
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
