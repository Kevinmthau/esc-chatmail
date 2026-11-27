#if os(iOS)
import XCTest
import UIKit
@testable import esc_chatmail

final class ImageRequestManagerTests: XCTestCase {
    func testLoadImageDoesNotCacheRemoteConfigDisabledLoadsAsFailures() async {
        let remoteConfig = TestRemoteConfigProvider(
            flags: [.remoteImageLoadingEnabled: false]
        )
        let imageFetcher = CountingRemoteImageFetcher()
        let manager = ImageRequestManager(
            imageFetcher: imageFetcher,
            remoteConfig: remoteConfig
        )
        let url = "https://example.com/avatar.png"

        let disabledResult = await manager.loadImage(from: url) { _ in
            XCTFail("Disabled remote image loading should not complete with an image")
        }

        XCTAssertNil(disabledResult)
        let disabledRequestCount = await imageFetcher.requestCount
        XCTAssertEqual(disabledRequestCount, 0)

        await remoteConfig.setEnabled(.remoteImageLoadingEnabled, true)

        let enabledResult = await manager.loadImage(from: url) { _ in }

        XCTAssertNotNil(enabledResult)
        let enabledRequestCount = await imageFetcher.requestCount
        XCTAssertEqual(enabledRequestCount, 1)
    }

    // A failure for now (offline, a timeout) is refused for the retry interval and fetched
    // again after it. Before, every failure went into the process-lifetime set, so one
    // offline view left a card's image a placeholder until relaunch (architecture review
    // 2026-11, networking#6, caching-memory#2).
    // Revert-check: fails if a transient failure goes into `failedURLs` (the third load
    // makes no request and answers nil), or if the retry interval is not honoured (the
    // second load makes a request).
    func testTransientFailure_isNotRefetchedBeforeTheInterval_andIsAfterIt() async {
        let clock = SettableClock()
        let imageFetcher = ScriptedRemoteImageFetcher(outcomes: [.transientFailure, .image(UIImage())])
        let manager = ImageRequestManager(
            imageFetcher: imageFetcher,
            remoteConfig: TestRemoteConfigProvider(flags: [.remoteImageLoadingEnabled: true]),
            transientFailureRetryInterval: 30,
            now: { clock.now() }
        )
        let url = "https://example.com/hero.png"

        let failed = await manager.loadImage(from: url) { _ in XCTFail("A failed fetch completes nothing") }
        XCTAssertNil(failed)

        clock.advance(by: 29)
        let tooSoon = await manager.loadImage(from: url) { _ in XCTFail("A refused load completes nothing") }
        XCTAssertNil(tooSoon)
        let requestsBeforeTheInterval = await imageFetcher.requestCount
        XCTAssertEqual(requestsBeforeTheInterval, 1, "Within the interval the URL is not asked for again")

        clock.advance(by: 1)
        let retried = await manager.loadImage(from: url) { _ in }
        XCTAssertNotNil(retried)
        let requestsAfterTheInterval = await imageFetcher.requestCount
        XCTAssertEqual(requestsAfterTheInterval, 2)
    }

    // Revert-check: fails if a definitive failure is remembered only for the interval (the
    // second load, a day later, makes a request).
    func testDefinitiveFailure_isNeverRefetched() async {
        let clock = SettableClock()
        let imageFetcher = ScriptedRemoteImageFetcher(outcomes: [.definitiveFailure, .image(UIImage())])
        let manager = ImageRequestManager(
            imageFetcher: imageFetcher,
            remoteConfig: TestRemoteConfigProvider(flags: [.remoteImageLoadingEnabled: true]),
            now: { clock.now() }
        )
        let url = "https://example.com/gone.png"

        let failed = await manager.loadImage(from: url) { _ in }
        clock.advance(by: 24 * 60 * 60)
        let later = await manager.loadImage(from: url) { _ in }

        XCTAssertNil(failed)
        XCTAssertNil(later)
        let requestCount = await imageFetcher.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    // Revert-check: fails if `clearFailedURLs` forgets only one kind of failure.
    func testClearFailedURLs_forgetsBothKindsOfFailure() async {
        let imageFetcher = ScriptedRemoteImageFetcher(
            outcomes: [.definitiveFailure, .transientFailure, .image(UIImage())]
        )
        let manager = ImageRequestManager(
            imageFetcher: imageFetcher,
            remoteConfig: TestRemoteConfigProvider(flags: [.remoteImageLoadingEnabled: true])
        )
        _ = await manager.loadImage(from: "https://example.com/definitive.png") { _ in }
        _ = await manager.loadImage(from: "https://example.com/transient.png") { _ in }

        await manager.clearFailedURLs()

        let definitiveAgain = await manager.loadImage(from: "https://example.com/definitive.png") { _ in }
        let transientAgain = await manager.loadImage(from: "https://example.com/transient.png") { _ in }
        XCTAssertNotNil(definitiveAgain)
        XCTAssertNotNil(transientAgain)
        let requestCount = await imageFetcher.requestCount
        XCTAssertEqual(requestCount, 4)
    }

    func testLoadImageDoesNotCacheInFlightRemoteConfigDisabledLoadsAsFailures() async {
        let remoteConfig = TestRemoteConfigProvider(
            flags: [.remoteImageLoadingEnabled: true]
        )
        let imageFetcher = RemoteConfigDisablingImageFetcher(remoteConfig: remoteConfig)
        let manager = ImageRequestManager(
            imageFetcher: imageFetcher,
            remoteConfig: remoteConfig
        )
        let url = "https://example.com/in-flight.png"

        let disabledDuringFetchResult = await manager.loadImage(from: url) { _ in
            XCTFail("Disabled remote image loading should not complete with an image")
        }

        XCTAssertNil(disabledDuringFetchResult)
        let disabledDuringFetchRequestCount = await imageFetcher.requestCount
        XCTAssertEqual(disabledDuringFetchRequestCount, 1)

        await remoteConfig.setEnabled(.remoteImageLoadingEnabled, true)

        let retryResult = await manager.loadImage(from: url) { _ in }

        XCTAssertNotNil(retryResult)
        let retryRequestCount = await imageFetcher.requestCount
        XCTAssertEqual(retryRequestCount, 2)
    }
}

private actor CountingRemoteImageFetcher: RemoteImageFetching {
    private var requestedURLs: [String] = []

    var requestCount: Int {
        requestedURLs.count
    }

    func fetchImage(from urlString: String) async -> RemoteImageFetchOutcome {
        requestedURLs.append(urlString)
        return .image(UIImage())
    }
}

/// Answers each request with the next scripted outcome, repeating the last one.
private actor ScriptedRemoteImageFetcher: RemoteImageFetching {
    private var outcomes: [RemoteImageFetchOutcome]
    private var requestedURLs: [String] = []

    init(outcomes: [RemoteImageFetchOutcome]) {
        self.outcomes = outcomes
    }

    var requestCount: Int {
        requestedURLs.count
    }

    func fetchImage(from urlString: String) async -> RemoteImageFetchOutcome {
        requestedURLs.append(urlString)
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}

/// A clock the test moves. `@unchecked Sendable`: `lock` guards `date`.
private final class SettableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

private actor RemoteConfigDisablingImageFetcher: RemoteImageFetching {
    private let remoteConfig: TestRemoteConfigProvider
    private var shouldDisableOnNextRequest = true
    private var requestedURLs: [String] = []

    init(remoteConfig: TestRemoteConfigProvider) {
        self.remoteConfig = remoteConfig
    }

    var requestCount: Int {
        requestedURLs.count
    }

    func fetchImage(from urlString: String) async -> RemoteImageFetchOutcome {
        requestedURLs.append(urlString)

        if shouldDisableOnNextRequest {
            shouldDisableOnNextRequest = false
            await remoteConfig.setEnabled(.remoteImageLoadingEnabled, false)
            // The failure that would be remembered longest, to show the re-check.
            return .definitiveFailure
        }

        return .image(UIImage())
    }
}

private actor TestRemoteConfigProvider: RemoteConfigProvider {
    private var flags: [RemoteConfigFlag: Bool]

    init(flags: [RemoteConfigFlag: Bool]) {
        self.flags = flags
    }

    func isEnabled(_ flag: RemoteConfigFlag) async -> Bool {
        flags[flag] ?? true
    }

    func setEnabled(_ flag: RemoteConfigFlag, _ isEnabled: Bool) {
        flags[flag] = isEnabled
    }
}
#endif
