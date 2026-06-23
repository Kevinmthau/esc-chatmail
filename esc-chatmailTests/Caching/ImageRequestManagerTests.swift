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

    func image(from urlString: String) async -> UIImage? {
        requestedURLs.append(urlString)
        return UIImage()
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

    func image(from urlString: String) async -> UIImage? {
        requestedURLs.append(urlString)

        if shouldDisableOnNextRequest {
            shouldDisableOnNextRequest = false
            await remoteConfig.setEnabled(.remoteImageLoadingEnabled, false)
            return nil
        }

        return UIImage()
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
