import XCTest
@testable import esc_chatmail

final class SyncTimeCalculatorTests: XCTestCase {

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        // Clear any existing UserDefaults values that might affect tests
        UserDefaults.standard.removeObject(forKey: "installTimestamp")
        UserDefaults.standard.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
    }

    override func tearDown() {
        // Clean up after tests
        UserDefaults.standard.removeObject(forKey: "installTimestamp")
        UserDefaults.standard.removeObject(forKey: SyncConfig.lastSuccessfulSyncTimeKey)
        super.tearDown()
    }

    // MARK: - Initial Sync Config Tests

    func testInitialSync_withInstallTimestamp_usesInstallWithBuffer() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 3600 // 1 hour ago

        let result = SyncTimeCalculator.calculateStartTime(
            config: .initialSync,
            installTimestamp: installTime
        )

        // Should be install time minus 5-minute buffer
        let expected = installTime - SyncConfig.timestampBufferSeconds
        XCTAssertEqual(result, expected, accuracy: 1.0)
    }

    func testInitialSync_withoutInstallTimestamp_usesFallbackWindow() {
        let now = Date().timeIntervalSince1970

        let result = SyncTimeCalculator.calculateStartTime(
            config: .initialSync,
            installTimestamp: 0  // Explicitly pass 0 to simulate no install timestamp
        )

        // Should be now minus 30-day fallback window
        let expected = now - SyncConfig.initialSyncFallbackWindow
        XCTAssertEqual(result, expected, accuracy: 2.0)
    }

    func testInitialSync_ignoresLastSyncTime() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 3600 // 1 hour ago
        let lastSync = now - 600 // 10 minutes ago

        // Set last successful sync in UserDefaults
        UserDefaults.standard.set(lastSync, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let result = SyncTimeCalculator.calculateStartTime(
            config: .initialSync,
            installTimestamp: installTime
        )

        // Initial sync should NOT use last sync time, should use install time
        let expected = installTime - SyncConfig.timestampBufferSeconds
        XCTAssertEqual(result, expected, accuracy: 1.0)
    }

    // MARK: - History Recovery Config Tests

    func testHistoryRecovery_withLastSyncTime_usesLastSyncWithBuffer() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 86400 // 1 day ago
        let lastSync = now - 3600 // 1 hour ago

        // Set install timestamp
        UserDefaults.standard.set(installTime, forKey: "installTimestamp")
        // Set last successful sync
        UserDefaults.standard.set(lastSync, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let result = SyncTimeCalculator.calculateStartTime(config: .historyRecovery)

        // Should be last sync minus 10-minute recovery buffer
        let expected = lastSync - SyncConfig.recoveryBufferSeconds
        XCTAssertEqual(result, expected, accuracy: 1.0)
    }

    func testHistoryRecovery_withoutLastSyncTime_fallsBackToInstall() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 3600 // 1 hour ago

        let result = SyncTimeCalculator.calculateStartTime(
            config: .historyRecovery,
            installTimestamp: installTime
        )

        // No last sync, should use install time minus 5-minute buffer
        let expected = installTime - SyncConfig.timestampBufferSeconds
        XCTAssertEqual(result, expected, accuracy: 1.0)
    }

    func testHistoryRecovery_withoutAnyTimestamps_usesRecoveryFallback() {
        let now = Date().timeIntervalSince1970

        let result = SyncTimeCalculator.calculateStartTime(
            config: .historyRecovery,
            installTimestamp: 0
        )

        // Should use 7-day recovery fallback window
        let expected = now - SyncConfig.recoveryFallbackWindow
        XCTAssertEqual(result, expected, accuracy: 2.0)
    }

    func testHistoryRecovery_respectsInstallCutoff() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 1800 // 30 minutes ago
        let lastSync = now - 600 // 10 minutes ago

        UserDefaults.standard.set(lastSync, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let result = SyncTimeCalculator.calculateStartTime(
            config: .historyRecovery,
            installTimestamp: installTime
        )

        // lastSync - recoveryBuffer = now - 600 - 600 = now - 1200
        // installCutoff = installTime - timestampBuffer = now - 1800 - 300 = now - 2100
        // Since lastSync - buffer > installCutoff, should use lastSync - buffer
        let expected = lastSync - SyncConfig.recoveryBufferSeconds
        XCTAssertEqual(result, expected, accuracy: 1.0)
    }

    // MARK: - Reconciliation Config Tests

    func testReconciliation_respectsMaxWindow() {
        let now = Date().timeIntervalSince1970
        let installTime = now - (48 * 3600) // 48 hours ago
        let lastSync = now - (36 * 3600) // 36 hours ago (before max window)

        UserDefaults.standard.set(installTime, forKey: "installTimestamp")
        UserDefaults.standard.set(lastSync, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let result = SyncTimeCalculator.calculateStartTime(config: .reconciliation)

        // lastSync is 36 hours ago, but max window is 24 hours
        // So result should be capped at now - 24 hours
        let maxAllowed = now - SyncConfig.maxReconciliationWindow
        XCTAssertGreaterThanOrEqual(result, maxAllowed - 1.0)  // Allow 1s tolerance
    }

    func testReconciliation_recentLastSync_usesLastSync() {
        let now = Date().timeIntervalSince1970
        let installTime = now - (48 * 3600) // 48 hours ago
        let lastSync = now - 3600 // 1 hour ago (within max window)

        UserDefaults.standard.set(installTime, forKey: "installTimestamp")
        UserDefaults.standard.set(lastSync, forKey: SyncConfig.lastSuccessfulSyncTimeKey)

        let result = SyncTimeCalculator.calculateStartTime(config: .reconciliation)

        // lastSync is within 24-hour window, should use it minus buffer
        let expected = lastSync - SyncConfig.timestampBufferSeconds
        XCTAssertEqual(result, expected, accuracy: 1.0)
    }

    func testReconciliation_withoutLastSync_usesReconciliationFallback() {
        let now = Date().timeIntervalSince1970

        let result = SyncTimeCalculator.calculateStartTime(
            config: .reconciliation,
            installTimestamp: 0
        )

        // Should use 1-hour reconciliation interval as fallback
        let expected = now - SyncConfig.reconciliationInterval
        XCTAssertEqual(result, expected, accuracy: 2.0)
    }

    // MARK: - calculateStartDate Tests

    func testCalculateStartDate_returnsCorrectDate() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 3600

        let result = SyncTimeCalculator.calculateStartDate(
            config: .initialSync,
            installTimestamp: installTime
        )

        let expected = Date(timeIntervalSince1970: installTime - SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(result.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - buildSyncQuery Tests

    func testBuildSyncQuery_formatsCorrectly() {
        let now = Date().timeIntervalSince1970
        let installTime = now - 3600

        let result = SyncTimeCalculator.buildSyncQuery(
            config: .initialSync,
            installTimestamp: installTime
        )

        let expectedTimestamp = Int(installTime - SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(result, "after:\(expectedTimestamp) -label:spam -label:drafts")
    }

    func testBuildSyncQuery_containsRequiredExclusions() {
        let result = SyncTimeCalculator.buildSyncQuery(
            config: .initialSync,
            installTimestamp: Date().timeIntervalSince1970
        )

        XCTAssertTrue(result.contains("-label:spam"))
        XCTAssertTrue(result.contains("-label:drafts"))
        XCTAssertTrue(result.hasPrefix("after:"))
    }

    // MARK: - Config Presets Tests

    func testInitialSyncConfig_hasCorrectValues() {
        let config = SyncTimeCalculator.Config.initialSync

        XCTAssertEqual(config.primaryBuffer, SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(config.installBuffer, SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(config.fallbackWindow, SyncConfig.initialSyncFallbackWindow)
        XCTAssertNil(config.maxWindow)
        XCTAssertFalse(config.useLastSyncAsPrimary)
    }

    func testHistoryRecoveryConfig_hasCorrectValues() {
        let config = SyncTimeCalculator.Config.historyRecovery

        XCTAssertEqual(config.primaryBuffer, SyncConfig.recoveryBufferSeconds)
        XCTAssertEqual(config.installBuffer, SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(config.fallbackWindow, SyncConfig.recoveryFallbackWindow)
        XCTAssertNil(config.maxWindow)
        XCTAssertTrue(config.useLastSyncAsPrimary)
    }

    func testReconciliationConfig_hasCorrectValues() {
        let config = SyncTimeCalculator.Config.reconciliation

        XCTAssertEqual(config.primaryBuffer, SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(config.installBuffer, SyncConfig.timestampBufferSeconds)
        XCTAssertEqual(config.fallbackWindow, SyncConfig.reconciliationInterval)
        XCTAssertEqual(config.maxWindow, SyncConfig.maxReconciliationWindow)
        XCTAssertTrue(config.useLastSyncAsPrimary)
    }
}
