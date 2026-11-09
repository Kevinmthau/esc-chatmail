import SwiftUI
import XCTest
@testable import esc_chatmail

/// Pins when the foreground sync session starts and stops on each platform.
/// The `App` struct that carries these decisions out runs under no test plan,
/// and the Mac rules run here on iOS because the platform is an input.
final class AppLifecyclePolicyTests: XCTestCase {

    // MARK: - Scene phase

    func testSyncActionForScenePhase_iOSBackground_stopsSyncAndArmsBackgroundTasks() {
        XCTAssertEqual(
            AppLifecyclePolicy.syncAction(
                forScenePhase: .background,
                platform: .iOS,
                isInitialized: true,
                canAccessMailbox: true
            ),
            .stopForegroundSyncAndArmBackgroundTasks
        )
    }

    /// The BGTask arm applies its own canAccessMailbox gate, so the scene
    /// handler stops and arms unconditionally, as it did before the policy.
    func testSyncActionForScenePhase_iOSBackgroundBeforeInitWithoutMailbox_stillStopsAndArms() {
        XCTAssertEqual(
            AppLifecyclePolicy.syncAction(
                forScenePhase: .background,
                platform: .iOS,
                isInitialized: false,
                canAccessMailbox: false
            ),
            .stopForegroundSyncAndArmBackgroundTasks
        )
    }

    // Revert-check: fails if `AppLifecyclePolicy.syncAction(forScenePhase:...)`
    // treats a Mac `.background` phase like iOS's. A hidden, minimized or
    // closed window would then stop sync while the app keeps running.
    func testSyncActionForScenePhase_macOSBackground_keepsSyncRunning() {
        for isInitialized in [true, false] {
            for canAccessMailbox in [true, false] {
                XCTAssertEqual(
                    AppLifecyclePolicy.syncAction(
                        forScenePhase: .background,
                        platform: .macOS,
                        isInitialized: isInitialized,
                        canAccessMailbox: canAccessMailbox
                    ),
                    .none
                )
            }
        }
    }

    func testSyncActionForScenePhase_activeAfterInitWithMailbox_startsSyncOnBothPlatforms() {
        for platform in [AppPlatform.iOS, .macOS] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(
                    forScenePhase: .active,
                    platform: platform,
                    isInitialized: true,
                    canAccessMailbox: true
                ),
                .startForegroundSync
            )
        }
    }

    func testSyncActionForScenePhase_activeBeforeInit_startsNothing() {
        for platform in [AppPlatform.iOS, .macOS] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(
                    forScenePhase: .active,
                    platform: platform,
                    isInitialized: false,
                    canAccessMailbox: true
                ),
                .none
            )
        }
    }

    func testSyncActionForScenePhase_activeWithoutMailbox_startsNothing() {
        for platform in [AppPlatform.iOS, .macOS] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(
                    forScenePhase: .active,
                    platform: platform,
                    isInitialized: true,
                    canAccessMailbox: false
                ),
                .none
            )
        }
    }

    func testSyncActionForScenePhase_inactive_doesNothing() {
        for platform in [AppPlatform.iOS, .macOS] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(
                    forScenePhase: .inactive,
                    platform: platform,
                    isInitialized: true,
                    canAccessMailbox: true
                ),
                .none
            )
        }
    }

    // MARK: - Initialization

    func testSyncActionAfterInitialization_iOSInBackground_armsBackgroundTasks() {
        XCTAssertEqual(
            AppLifecyclePolicy.syncActionAfterInitialization(
                platform: .iOS,
                isApplicationInBackground: true,
                canAccessMailbox: true
            ),
            .armBackgroundTasks
        )
    }

    func testSyncActionAfterInitialization_iOSInForeground_startsSync() {
        XCTAssertEqual(
            AppLifecyclePolicy.syncActionAfterInitialization(
                platform: .iOS,
                isApplicationInBackground: false,
                canAccessMailbox: true
            ),
            .startForegroundSync
        )
    }

    // Revert-check: fails if `AppLifecyclePolicy.syncActionAfterInitialization`
    // lets the background flag decide on the Mac. The Mac has no BGTasks to
    // arm, so a launch that finished "in the background" would start nothing.
    func testSyncActionAfterInitialization_macOS_alwaysStartsSync() {
        for isApplicationInBackground in [true, false] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncActionAfterInitialization(
                    platform: .macOS,
                    isApplicationInBackground: isApplicationInBackground,
                    canAccessMailbox: true
                ),
                .startForegroundSync
            )
        }
    }

    func testSyncActionAfterInitialization_withoutMailbox_doesNothingOnBothPlatforms() {
        for platform in [AppPlatform.iOS, .macOS] {
            for isApplicationInBackground in [true, false] {
                XCTAssertEqual(
                    AppLifecyclePolicy.syncActionAfterInitialization(
                        platform: platform,
                        isApplicationInBackground: isApplicationInBackground,
                        canAccessMailbox: false
                    ),
                    .none
                )
            }
        }
    }

    // MARK: - Mac system events

    // Revert-check: fails if `AppLifecyclePolicy.syncAction(forSystemEvent:...)`
    // stops answering system sleep with a stop, which would leave the
    // session's timer firing syncs across the sleep transition.
    func testSyncActionForSystemEvent_willSleep_stopsSyncWhateverTheMailboxState() {
        for canAccessMailbox in [true, false] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(forSystemEvent: .systemWillSleep, canAccessMailbox: canAccessMailbox),
                .stopForegroundSync
            )
        }
    }

    func testSyncActionForSystemEvent_wakeOrActivationWithMailbox_startsSync() {
        for event in [AppLifecyclePolicy.SystemEvent.systemDidWake, .applicationDidBecomeActive] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(forSystemEvent: event, canAccessMailbox: true),
                .startForegroundSync
            )
        }
    }

    func testSyncActionForSystemEvent_wakeOrActivationWithoutMailbox_startsNothing() {
        for event in [AppLifecyclePolicy.SystemEvent.systemDidWake, .applicationDidBecomeActive] {
            XCTAssertEqual(
                AppLifecyclePolicy.syncAction(forSystemEvent: event, canAccessMailbox: false),
                .none
            )
        }
    }

    // MARK: - Auth changes

    func testAllowsForegroundSyncStartOnAuthChange_iOS_onlyWhileActive() {
        XCTAssertTrue(AppLifecyclePolicy.allowsForegroundSyncStartOnAuthChange(platform: .iOS, scenePhase: .active))
        XCTAssertFalse(AppLifecyclePolicy.allowsForegroundSyncStartOnAuthChange(platform: .iOS, scenePhase: .inactive))
        XCTAssertFalse(AppLifecyclePolicy.allowsForegroundSyncStartOnAuthChange(platform: .iOS, scenePhase: .background))
    }

    // Revert-check: fails if `AppLifecyclePolicy.allowsForegroundSyncStartOnAuthChange`
    // requires `.active` on the Mac too. Signing in or finishing
    // reauthentication while the window is hidden would then start no sync,
    // and nothing else restarts the session until the app is next activated.
    func testAllowsForegroundSyncStartOnAuthChange_macOS_anyScenePhase() {
        for phase in [ScenePhase.active, .inactive, .background] {
            XCTAssertTrue(AppLifecyclePolicy.allowsForegroundSyncStartOnAuthChange(platform: .macOS, scenePhase: phase))
        }
    }

    // MARK: - Termination

    func testTerminationDecision_noOutstandingSends_terminatesNow() {
        XCTAssertEqual(AppLifecyclePolicy.terminationDecision(hasOutstandingSends: false), .terminateNow)
    }

    // Revert-check: fails if `AppLifecyclePolicy.terminationDecision` stops
    // holding the quit for a send in flight, or drops the bound on the wait.
    func testTerminationDecision_outstandingSends_waitsAtMostTenSeconds() {
        XCTAssertEqual(
            AppLifecyclePolicy.terminationDecision(hasOutstandingSends: true),
            .terminateAfterOutstandingSends(timeout: 10)
        )
    }
}
