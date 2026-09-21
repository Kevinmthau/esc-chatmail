import XCTest
@testable import esc_chatmail

final class BackgroundSyncStateManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BackgroundSyncStateManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // Revert-check: removing the legacy-key deletion leaves the old payload
    // behind, regardless of whether it is still valid JSON.
    func testClearContinuationState_removesLegacyAndMalformedCheckpoints() {
        let legacyJSON = #"""
        {
          "mode": "partial",
          "pageToken": "page-2",
          "startHistoryId": "history-expired",
          "query": "after:123 -label:spam",
          "maxResults": 50,
          "accountEmail": "test@example.com",
          "watermarkHistoryId": "history-watermark"
        }
        """#
        for payload in [Data(legacyJSON.utf8), Data("malformed checkpoint".utf8)] {
            defaults.set(payload, forKey: "backgroundSync.continuationState")

            BackgroundSyncStateManager.clearContinuationState(in: defaults)

            XCTAssertNil(defaults.object(forKey: "backgroundSync.continuationState"))
        }
    }
}
