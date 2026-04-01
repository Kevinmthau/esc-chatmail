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

    private var shouldForceAuthenticatedUITestState: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TEST_AUTHENTICATED")
    }

    init() {
        logStartupTiming("App init started")

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

        // 1. Fresh install check (awaited - completes before continuing)
        await FreshInstallHandler().checkAndHandleFreshInstall()
        logStartupTiming("FreshInstallHandler complete")

        // 2. Only start Core Data loading after fresh-install cleanup has had a chance to reset it.
        _ = CoreDataStack.shared.persistentContainer
        logStartupTiming("Core Data container accessed")

        // 3. Wait for Core Data store to load
        await waitForCoreData()
        logStartupTiming("Core Data ready")

        // 4. Start cache coordinator for Core Data change notifications
        CacheCoordinator.shared.start()
        logStartupTiming("CacheCoordinator started")

        if !isRunningUITests {
            DatabaseMaintenanceService.shared.scheduleMaintenanceTasks()
            logStartupTiming("Database maintenance scheduled")
        }

        // 5. Restore auth session (after cleanup complete)
        await AuthSession.shared.restorePreviousSignIn()
        applyUITestLaunchStateIfNeeded()
        logStartupTiming("Auth restored")

        // Start app-scoped foreground sync as soon as auth is available.
        // Scene callbacks may not fire during cold-start when already active.
        if dependencies.authSession.isAuthenticated && !isRunningUITests {
            dependencies.foregroundSyncCoordinator.start(
                reason: "appInitialized",
                triggerImmediateSync: true
            )
        }

        // 6. Ready to show main UI
        isInitialized = true
        logStartupTiming("initializeApp() complete")

        // 7. Prewarm WebKit after UI becomes available to avoid launch-path contention.
        if !isRunningUITests {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                AppPrewarmer.prewarmWebKitIfNeeded()
                logStartupTiming("WebKit prewarm triggered (post-init)")
            }
        }
    }

    private func waitForCoreData() async {
        let startTime = Date()
        let timeout: TimeInterval = 10.0

        while !CoreDataStack.shared.isStoreLoaded {
            if Date().timeIntervalSince(startTime) > timeout {
                Log.error("Core Data store load timeout", category: .coreData)
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
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
            if dependencies.authSession.isAuthenticated {
                dependencies.backgroundSyncManager.scheduleAppRefresh()
                dependencies.backgroundSyncManager.scheduleProcessingTask()
            }
        case .active:
            // Foreground sync is now app-scoped (independent of the conversation list lifecycle).
            // Also process pending actions and duplicate cleanup.
            if dependencies.authSession.isAuthenticated {
                dependencies.foregroundSyncCoordinator.start(
                    reason: "sceneActive",
                    triggerImmediateSync: true
                )
                Task {
                    await dependencies.pendingActionsManager.processAllPendingActions()
                }
            }
        case .inactive:
            dependencies.foregroundSyncCoordinator.stop(reason: "sceneInactive")
            break
        @unknown default:
            break
        }
    }

    private func handleAuthStateChange(_ isAuthenticated: Bool) {
        if isRunningUITests { return }

        if isAuthenticated && scenePhase == .active {
            dependencies.foregroundSyncCoordinator.start(
                reason: "authBecameAuthenticated",
                triggerImmediateSync: true
            )
        } else if !isAuthenticated {
            dependencies.foregroundSyncCoordinator.stop(reason: "authBecameUnauthenticated")
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
