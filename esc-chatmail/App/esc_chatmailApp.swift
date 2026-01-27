//
//  esc_chatmailApp.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI
import GoogleSignIn
import BackgroundTasks

#if DEBUG
private let appStartTime = Date()
#endif

private func logStartupTiming(_ message: String) {
    #if DEBUG
    let elapsed = Date().timeIntervalSince(appStartTime)
    Log.info("STARTUP[\(String(format: "%.3f", elapsed))s]: \(message)", category: .general)
    #endif
}

@main
struct esc_chatmailApp: App {
    @StateObject private var dependencies = Dependencies.shared
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var isInitialized = false

    init() {
        logStartupTiming("App init started")

        configureGoogleSignIn()
        logStartupTiming("GoogleSignIn configured")

        configureBackgroundTasks()
        logStartupTiming("BackgroundTasks configured")

        // Trigger Core Data stack initialization (async load starts here)
        _ = CoreDataStack.shared.persistentContainer
        logStartupTiming("Core Data container accessed")

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

        // Start WebKit prewarm FIRST - 12s GPU launch runs in background
        // This overlaps the GPU process launch with auth restoration and initial UI rendering
        AppPrewarmer.prewarmWebKitIfNeeded()
        logStartupTiming("WebKit prewarm triggered")

        // 1. Fresh install check (awaited - completes before continuing)
        await FreshInstallHandler().checkAndHandleFreshInstall()
        logStartupTiming("FreshInstallHandler complete")

        // 2. Wait for Core Data store to load
        await waitForCoreData()
        logStartupTiming("Core Data ready")

        // 3. Start cache coordinator for Core Data change notifications
        CacheCoordinator.shared.start()
        logStartupTiming("CacheCoordinator started")

        // 4. Restore auth session (after cleanup complete)
        await AuthSession.shared.restorePreviousSignIn()
        logStartupTiming("Auth restored")

        // 5. Ready to show main UI
        isInitialized = true
        logStartupTiming("initializeApp() complete")
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
    
    private func runDuplicateCleanup() async {
        let context = CoreDataStack.shared.newBackgroundContext()
        let conversationManager = ConversationManager()
        await conversationManager.mergeActiveConversationDuplicates(in: context)
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if dependencies.authSession.isAuthenticated {
                dependencies.backgroundSyncManager.scheduleAppRefresh()
                dependencies.backgroundSyncManager.scheduleProcessingTask()
            }
        case .active:
            // Note: Sync is handled by ConversationListView.onAppear to avoid duplicate syncs
            // Only process pending actions here (lightweight operation)
            if dependencies.authSession.isAuthenticated {
                Task {
                    await dependencies.pendingActionsManager.processAllPendingActions()
                    // Run lightweight duplicate cleanup on app activation
                    await runDuplicateCleanup()
                }
            }
        case .inactive:
            break
        @unknown default:
            break
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
