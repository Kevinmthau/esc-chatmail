//
//  esc_chatmailApp.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI
import GoogleSignIn
import BackgroundTasks

private let appStartTime = Date()

private func logStartupTiming(_ message: String) {
    let elapsed = Date().timeIntervalSince(appStartTime)
    Log.diagnostic(.startup, level: .info, "STARTUP[\(String(format: "%.3f", elapsed))s]: \(message)", category: .general)
}

@main
struct esc_chatmailApp: App {
    @StateObject private var dependencies = Dependencies.shared
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var isInitialized = false

    private var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TEST_MODE")
    }

    private var isRunningUnitTests: Bool {
        RuntimeEnvironment.isRunningUnitTests
    }

    private var shouldForceAuthenticatedUITestState: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TEST_AUTHENTICATED")
    }

    init() {
        logStartupTiming("App init started")

        // When hosting unit tests, load the shared Core Data stack now —
        // synchronously, before XCTest starts executing tests. Some tests
        // construct services whose initializers default to
        // `coreDataStack: .shared`; the first such touch would otherwise
        // lazily load the model and store mid-suite, re-registering global
        // entity↔class mappings concurrently with running tests.
        if isRunningUnitTests {
            _ = CoreDataStack.shared.persistentContainer
            logStartupTiming("Unit test host — shared Core Data stack preloaded")
        }

        configureGoogleSignIn()
        logStartupTiming("GoogleSignIn configured")

        configureBackgroundTasks()
        logStartupTiming("BackgroundTasks configured")

        // Setup attachment directories
        AttachmentPaths.setupDirectories()
        logStartupTiming("Directories setup")

        // NOTE: Fresh install check and auth restoration moved to initializeApp()
        // to properly await async operations before showing ContentView
        logStartupTiming("App init complete")
    }
    
    var body: some Scene {
        WindowGroup {
            if isInitialized {
                ContentView()
                    .environment(\.managedObjectContext, dependencies.viewContext)
                    .environmentObject(dependencies)
                    .environmentObject(dependencies.authSession) // backward compatibility
                    .onOpenURL { url in
                        GIDSignIn.sharedInstance.handle(url)
                    }
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        handleScenePhaseChange(newPhase)
                    }
                    .onChange(of: dependencies.authSession.isAuthenticated) { _, isAuthenticated in
                        handleAuthStateChange(isAuthenticated)
                    }
                    .onChange(of: dependencies.authSession.requiresReauthentication) { _, isRequired in
                        handleReauthenticationRequirementChange(isRequired)
                    }
            } else {
                AppLoadingView()
                    .task {
                        logStartupTiming("AppLoadingView.task started")
                        await initializeApp()
                    }
            }
        }
    }

    private func initializeApp() async {
        logStartupTiming("initializeApp() started")

        // Unit tests run hosted inside this process. Keep the app idle so its
        // startup machinery (fresh-install handling, Core Data store load,
        // CacheCoordinator's global save observer, maintenance scheduling,
        // auth restore, sync, ContentView's fetch requests) never runs
        // concurrently with the test suite. CacheCoordinator in particular
        // reacts to *every* NSManagedObjectContextDidSave in the process —
        // including saves of per-test in-memory stacks — scheduling async
        // Core Data work on test contexts that races the tests themselves.
        if isRunningUnitTests {
            logStartupTiming("Unit test host detected — app initialization skipped")
            return
        }

        // 1. Fresh-install cleanup and store loading are single-flight because
        // a cold BGTask launch may request the same prerequisites concurrently.
        guard await AppStartupBootstrap.shared.preparePersistenceUntilReady() else {
            logStartupTiming("Persistence bootstrap stopped before readiness")
            return
        }
        logStartupTiming("Fresh-install and Core Data bootstrap complete")

        // 2. Start cache coordinator for Core Data change notifications
        CacheCoordinator.shared.start()
        logStartupTiming("CacheCoordinator started")

        if !isRunningUITests {
            DatabaseMaintenanceService.shared.scheduleMaintenanceTasks()
            logStartupTiming("Database maintenance scheduled")
        }

        // 3. Restore auth session (after cleanup complete). A cold background
        // launch may already own this single-flight phase, in which case the UI
        // joins it instead of starting a second account transition.
        guard await AppStartupBootstrap.shared.restoreAuthenticationIfNeeded() else {
            logStartupTiming("Auth bootstrap failed")
            return
        }
        applyUITestLaunchStateIfNeeded()
        logStartupTiming("Auth restored")

        if reconcileAbandonedOptimisticSendsIfAuthenticated() {
            logStartupTiming("Abandoned optimistic sends reconciled")
        }

        // Start app-scoped foreground sync as soon as auth is available.
        // Scene callbacks may not fire during cold-start when already active.
        if dependencies.authSession.canAccessMailbox && !isRunningUITests {
            startForegroundSyncSession(
                reason: "appInitialized",
                triggerImmediateSync: true,
                processPendingActionsIfStarted: true
            )
        }

        // 4. Ready to show main UI
        isInitialized = true
        await dependencies.telemetryClient.record(
            TelemetryEvent(
                name: .appLaunch,
                attributes: [.outcome: "initialized"]
            )
        )
        logStartupTiming("initializeApp() complete")

        // 5. Prewarm WebKit after UI becomes available to avoid launch-path contention.
        if !isRunningUITests {
            Task { @MainActor in
                guard await Task.sleepUnlessCancelled(nanoseconds: 2_000_000_000) else { return }
                AppPrewarmer.prewarmWebKitIfNeeded()
                logStartupTiming("WebKit prewarm triggered (post-init)")
            }
        }
    }

    private func configureGoogleSignIn() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: GoogleConfig.clientId
        )
    }
    
    private func configureBackgroundTasks() {
        BackgroundSyncManager.shared.registerBackgroundTasks()
    }
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if isRunningUITests { return }

        switch newPhase {
        case .background:
            dependencies.foregroundSyncCoordinator.stop(reason: "sceneBackground")
            if dependencies.authSession.canAccessMailbox {
                dependencies.backgroundSyncManager.scheduleAppRefresh()
                dependencies.backgroundSyncManager.scheduleProcessingTask()
            }
        case .active:
            // Foreground sync is now app-scoped (independent of the conversation list lifecycle).
            // Also process pending actions and duplicate cleanup.
            if dependencies.authSession.canAccessMailbox {
                startForegroundSyncSession(
                    reason: "sceneActive",
                    triggerImmediateSync: true,
                    processPendingActionsIfStarted: true
                )
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleAuthStateChange(_ isAuthenticated: Bool) {
        if isRunningUITests { return }

        if isAuthenticated,
           dependencies.authSession.canAccessMailbox,
           scenePhase == .active {
            reconcileAbandonedOptimisticSendsIfAuthenticated()
            startForegroundSyncSession(
                reason: "authBecameAuthenticated",
                triggerImmediateSync: true,
                processPendingActionsIfStarted: true
            )
        } else if !isAuthenticated {
            dependencies.foregroundSyncCoordinator.stop(reason: "authBecameUnauthenticated")
        }
    }

    private func handleReauthenticationRequirementChange(_ isRequired: Bool) {
        if isRunningUITests { return }

        if isRequired {
            dependencies.foregroundSyncCoordinator.stop(reason: "reauthenticationRequired")
        } else if dependencies.authSession.canAccessMailbox && scenePhase == .active {
            reconcileAbandonedOptimisticSendsIfAuthenticated()
            startForegroundSyncSession(
                reason: "reauthenticationCompleted",
                triggerImmediateSync: true,
                processPendingActionsIfStarted: true
            )
        }
    }

    @discardableResult
    private func reconcileAbandonedOptimisticSendsIfAuthenticated() -> Bool {
        guard dependencies.authSession.canAccessMailbox else { return false }
        return dependencies.makeSendService().reconcileAbandonedOptimisticSendMutations()
    }

    private func startForegroundSyncSession(
        reason: String,
        triggerImmediateSync: Bool,
        processPendingActionsIfStarted: Bool
    ) {
        let startedSession = dependencies.foregroundSyncCoordinator.start(
            reason: reason,
            triggerImmediateSync: triggerImmediateSync
        )

        guard processPendingActionsIfStarted, startedSession else {
            return
        }

        Task {
            let hadPendingActions = await dependencies.pendingActionsManager.pendingActionCount() > 0
            await dependencies.pendingActionsManager.processAllPendingActions()
            if hadPendingActions {
                await MainActor.run {
                    dependencies.foregroundSyncCoordinator.triggerSyncAfterCurrent(
                        reason: "\(reason)PostPendingActions",
                        force: true
                    )
                }
            }
        }
    }

    private func applyUITestLaunchStateIfNeeded() {
        guard isRunningUITests, shouldForceAuthenticatedUITestState else { return }
        dependencies.authSession.isAuthenticated = true
        if dependencies.authSession.userEmail == nil {
            dependencies.authSession.userEmail = "uitest@example.com"
        }
        if dependencies.authSession.userName == nil {
            dependencies.authSession.userName = "UI Test"
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        // This is called when the app is about to terminate
        // Only clear memory cache, but preserve user session
        // Full cleanup only happens on fresh install detection
        Task {
            await AttachmentCacheActor.shared.clearCache(level: .moderate)
        }
    }
}
