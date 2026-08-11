import Security
import XCTest
@testable import esc_chatmail

@MainActor
final class FreshInstallHandlerTests: XCTestCase {
    func testTransientKeychainReadFailureDefersFreshInstallHandling() async {
        let defaults = makeDefaults()
        defaults.set("existing-installation", forKey: "AppInstallationID")
        defaults.set(123, forKey: "installTimestamp")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: {
                throw KeychainError.unhandledError(status: errSecInteractionNotAllowed)
            },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        let completed = await handler.checkAndHandleFreshInstall()
        let detections = await recorder.detections

        XCTAssertFalse(completed)
        XCTAssertEqual(defaults.string(forKey: "AppInstallationID"), "existing-installation")
        XCTAssertEqual(defaults.double(forKey: "installTimestamp"), 123)
        XCTAssertEqual(detections, [])
    }

    func testCorruptKeychainInstallationIdTriggersFailSafeCleanupInsteadOfRetrying() async {
        let defaults = makeDefaults()
        defaults.set("existing-installation", forKey: "AppInstallationID")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: { throw KeychainError.unexpectedData },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        let completed = await handler.checkAndHandleFreshInstall()
        let detections = await recorder.detections

        XCTAssertTrue(completed)
        XCTAssertEqual(detections, [false])
    }

    func testPermanentKeychainReadFailureTriggersFailSafeCleanupInsteadOfRetrying() async {
        let defaults = makeDefaults()
        defaults.set("existing-installation", forKey: "AppInstallationID")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: {
                throw KeychainError.unhandledError(status: errSecAuthFailed)
            },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        let completed = await handler.checkAndHandleFreshInstall()
        let detections = await recorder.detections

        XCTAssertTrue(completed)
        XCTAssertEqual(detections, [false])
    }

    func testMissingKeychainInstallationIdTriggersMismatchCleanup() async {
        let defaults = makeDefaults()
        defaults.set("existing-installation", forKey: "AppInstallationID")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: { throw KeychainError.itemNotFound },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        let completed = await handler.checkAndHandleFreshInstall()
        let detections = await recorder.detections

        XCTAssertTrue(completed)
        XCTAssertEqual(detections, [false])
    }

    func testDifferentKeychainInstallationIdTriggersMismatchCleanup() async {
        let defaults = makeDefaults()
        defaults.set("defaults-installation", forKey: "AppInstallationID")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: { "keychain-installation" },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        let completed = await handler.checkAndHandleFreshInstall()
        let detections = await recorder.detections

        XCTAssertTrue(completed)
        XCTAssertEqual(detections, [true])
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "FreshInstallHandlerTests.\(UUID().uuidString)")!
    }
}

private actor FreshInstallCleanupRecorder {
    private(set) var detections: [Bool] = []

    func record(_ hasKeychainData: Bool) {
        detections.append(hasKeychainData)
    }
}
