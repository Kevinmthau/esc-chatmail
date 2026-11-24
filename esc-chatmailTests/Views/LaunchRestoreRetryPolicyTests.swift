import SwiftUI
import XCTest
@testable import esc_chatmail

final class LaunchRestoreRetryPolicyTests: XCTestCase {

    // MARK: - shouldAttempt

    // Revert-check: fails if `shouldAttempt` stops requiring a held account. A signed-out
    // device (or one durably signed out, which never holds) would run restores forever.
    func testShouldAttempt_noHeldAccount_neverAttempts() {
        for trigger in [LaunchRestoreRetryPolicy.Trigger.cameToForeground, .userAsked, .scheduled] {
            XCTAssertFalse(
                LaunchRestoreRetryPolicy.shouldAttempt(
                    trigger: trigger,
                    hasHeldAccount: false,
                    isAttemptInFlight: false,
                    secondsSinceLastAttemptStarted: nil
                ),
                "\(trigger)"
            )
        }
    }

    func testShouldAttempt_attemptInFlight_neverStartsAnother() {
        for trigger in [LaunchRestoreRetryPolicy.Trigger.cameToForeground, .userAsked, .scheduled] {
            XCTAssertFalse(
                LaunchRestoreRetryPolicy.shouldAttempt(
                    trigger: trigger,
                    hasHeldAccount: true,
                    isAttemptInFlight: true,
                    secondsSinceLastAttemptStarted: 100
                ),
                "\(trigger)"
            )
        }
    }

    // Revert-check: fails if the foreground case drops `minimumForegroundInterval`.
    func testShouldAttempt_foregroundRightAfterAnAttempt_isRefused() {
        XCTAssertFalse(
            LaunchRestoreRetryPolicy.shouldAttempt(
                trigger: .cameToForeground,
                hasHeldAccount: true,
                isAttemptInFlight: false,
                secondsSinceLastAttemptStarted: 1
            )
        )
        XCTAssertTrue(
            LaunchRestoreRetryPolicy.shouldAttempt(
                trigger: .cameToForeground,
                hasHeldAccount: true,
                isAttemptInFlight: false,
                secondsSinceLastAttemptStarted: LaunchRestoreRetryPolicy.minimumForegroundInterval
            )
        )
        XCTAssertTrue(
            LaunchRestoreRetryPolicy.shouldAttempt(
                trigger: .cameToForeground,
                hasHeldAccount: true,
                isAttemptInFlight: false,
                secondsSinceLastAttemptStarted: nil
            )
        )
    }

    func testShouldAttempt_userAndScheduled_ignoreTheForegroundInterval() {
        for trigger in [LaunchRestoreRetryPolicy.Trigger.userAsked, .scheduled] {
            XCTAssertTrue(
                LaunchRestoreRetryPolicy.shouldAttempt(
                    trigger: trigger,
                    hasHeldAccount: true,
                    isAttemptInFlight: false,
                    secondsSinceLastAttemptStarted: 0
                ),
                "\(trigger)"
            )
        }
    }

    // MARK: - Backoff

    func testAutomaticRetryDelay_doublesFromFifteenSecondsToFiveMinutes() {
        let delays = (0...8).map {
            LaunchRestoreRetryPolicy.automaticRetryDelay(afterConsecutiveFailures: $0)
        }
        XCTAssertEqual(delays, [15, 15, 30, 60, 120, 240, 300, 300, 300])
        XCTAssertEqual(LaunchRestoreRetryPolicy.automaticRetryDelay(afterConsecutiveFailures: 10_000), 300)
    }

    // MARK: - Lifecycle

    func testResponseToScenePhase_iOS_retriesOnActiveAndPausesInBackground() {
        XCTAssertEqual(LaunchRestoreRetryPolicy.response(toScenePhase: .active, platform: .iOS), .retry)
        XCTAssertEqual(LaunchRestoreRetryPolicy.response(toScenePhase: .background, platform: .iOS), .pause)
        XCTAssertEqual(LaunchRestoreRetryPolicy.response(toScenePhase: .inactive, platform: .iOS), .none)
    }

    /// The Mac's scene phase follows a window; its retries follow the app's activation and
    /// the system's sleep and wake instead.
    func testResponseToScenePhase_mac_isNone() {
        for phase in [ScenePhase.active, .background, .inactive] {
            XCTAssertEqual(LaunchRestoreRetryPolicy.response(toScenePhase: phase, platform: .macOS), .none)
        }
    }

    func testResponseToSystemEvent_macRetriesOnActivationAndWakeAndPausesForSleep() {
        XCTAssertEqual(LaunchRestoreRetryPolicy.response(toSystemEvent: .applicationDidBecomeActive), .retry)
        XCTAssertEqual(LaunchRestoreRetryPolicy.response(toSystemEvent: .systemDidWake), .retry)
        XCTAssertEqual(LaunchRestoreRetryPolicy.response(toSystemEvent: .systemWillSleep), .pause)
    }

    // MARK: - Background arm

    // Revert-check: fails if `AppLifecyclePolicy.armsBackgroundTasksOnAuthChange` stops
    // arming an iOS session published in the background.
    func testArmsBackgroundTasksOnAuthChange_onlyForIOSInTheBackground() {
        XCTAssertTrue(AppLifecyclePolicy.armsBackgroundTasksOnAuthChange(platform: .iOS, isApplicationInBackground: true))
        XCTAssertFalse(AppLifecyclePolicy.armsBackgroundTasksOnAuthChange(platform: .iOS, isApplicationInBackground: false))
        XCTAssertFalse(AppLifecyclePolicy.armsBackgroundTasksOnAuthChange(platform: .macOS, isApplicationInBackground: true))
    }

    // MARK: - Held screen

    func testHeldAccountMessage_namesTheAddressAndSaysTheMailIsStillHere() {
        let message = HeldAccountViewPolicy.message(
            for: HeldAccount(email: "person@example.com", failure: .cannotConnect)
        )
        XCTAssertTrue(message.contains("person@example.com"))
        XCTAssertTrue(message.contains("still on this device"))
        XCTAssertTrue(
            HeldAccountViewPolicy.message(for: HeldAccount(email: nil, failure: .couldNotRestore))
                .hasPrefix("Your mail is still on this device")
        )
        XCTAssertNotEqual(
            HeldAccountViewPolicy.title(for: .cannotConnect),
            HeldAccountViewPolicy.title(for: .couldNotRestore)
        )
    }
}
