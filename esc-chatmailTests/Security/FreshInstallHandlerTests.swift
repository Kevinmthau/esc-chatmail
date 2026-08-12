import Security
import XCTest
@testable import esc_chatmail

@MainActor
final class FreshInstallHandlerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The backstop counter is process-global; without an explicit reset,
        // deferral tests would accumulate reads across the suite and flip a
        // later test into the proceed-without-determination branch.
        FreshInstallHandler.resetIndeterminateReadBackstopForTesting()
    }

    // Revert-check: fails if the `indeterminateReadBackstop` guard is removed
    // from `checkAndHandleFreshInstall()`'s generic catch — a permanently
    // failing keychain (e.g. a missing entitlement) would then defer forever
    // and AppStartupBootstrap's 1 Hz retry loop would never load Core Data.
    // The backstop must proceed WITHOUT running any cleanup.
    func testPersistentKeychainReadFailureEventuallyProceedsWithoutCleanup() async {
        let defaults = makeDefaults()
        defaults.set("existing-installation", forKey: "AppInstallationID")
        defaults.set(123, forKey: "installTimestamp")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: {
                throw KeychainError.unhandledError(status: errSecMissingEntitlement)
            },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        var results: [Bool] = []
        for _ in 0..<5 {
            results.append(await handler.checkAndHandleFreshInstall())
        }
        let detections = await recorder.detections

        XCTAssertEqual(results, [false, false, false, false, true])
        XCTAssertEqual(detections, [], "The backstop must never run destructive cleanup on uncertainty")
        XCTAssertEqual(defaults.string(forKey: "AppInstallationID"), "existing-installation")
        XCTAssertEqual(defaults.double(forKey: "installTimestamp"), 123)
    }

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

    // Revert-check: both fail if `FreshInstallHandler.checkAndHandleFreshInstall()`'s
    // catch-all `return false` is narrowed back to `isTransientProtectedDataError`
    // (errSecInteractionNotAllowed only) with the fail-safe `keychainInstallationId =
    // nil`. Any other OSStatus would then report completion and drive the destructive
    // mismatch cleanup, wiping AppInstallationID/installTimestamp on a readable install.
    func testUnavailableKeychainReadDefersFreshInstallHandling() async {
        await assertUnhandledKeychainReadDefers(status: errSecNotAvailable)
    }

    func testKeychainIOFailureDefersFreshInstallHandling() async {
        await assertUnhandledKeychainReadDefers(status: errSecIO)
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

    // Revert-check: fails if `checkAndHandleFreshInstall()`'s generic `catch` stops
    // returning false and resumes treating an unhandled OSStatus as "no installation
    // ID" (the pre-fix `keychainInstallationId = nil` fail-safe). errSecAuthFailed
    // would then be indistinguishable from `KeychainError.itemNotFound` and trigger
    // cleanup with `hasKeychainData == false`.
    func testAuthorizationFailureDoesNotMasqueradeAsMissingInstallationId() async {
        await assertUnhandledKeychainReadDefers(status: errSecAuthFailed)
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

    private func assertUnhandledKeychainReadDefers(
        status: OSStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let defaults = makeDefaults()
        defaults.set("existing-installation", forKey: "AppInstallationID")
        defaults.set(123, forKey: "installTimestamp")
        let recorder = FreshInstallCleanupRecorder()
        let handler = FreshInstallHandler(
            userDefaults: defaults,
            loadInstallationId: {
                throw KeychainError.unhandledError(status: status)
            },
            handleDetectedFreshInstall: { hasKeychainData in
                await recorder.record(hasKeychainData)
            }
        )

        let completed = await handler.checkAndHandleFreshInstall()
        let detections = await recorder.detections

        XCTAssertFalse(completed, file: file, line: line)
        XCTAssertEqual(
            defaults.string(forKey: "AppInstallationID"),
            "existing-installation",
            file: file,
            line: line
        )
        XCTAssertEqual(defaults.double(forKey: "installTimestamp"), 123, file: file, line: line)
        XCTAssertEqual(detections, [], file: file, line: line)
    }
}

private actor FreshInstallCleanupRecorder {
    private(set) var detections: [Bool] = []

    func record(_ hasKeychainData: Bool) {
        detections.append(hasKeychainData)
    }
}
