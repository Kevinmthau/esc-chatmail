//
//  esc_chatmailApp.swift
//  esc-chatmail
//
//  Created by Kevin Thau on 9/1/25.
//

import SwiftUI
import GoogleSignIn
import BackgroundTasks

@main
struct esc_chatmailApp: App {
    @StateObject private var dependencies = Dependencies.shared
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var isInitialized = false

    init() {
        configureGoogleSignIn()
        configureBackgroundTasks()

        // Trigger Core Data stack initialization (async load starts here)
        _ = CoreDataStack.shared.persistentContainer

        // Setup attachment directories
        AttachmentPaths.setupDirectories()

        // NOTE: Fresh install check and auth restoration moved to initializeApp()
        // to properly await async operations before showing ContentView
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
                        await initializeApp()
                    }
            }
        }
    }

    private func initializeApp() async {
        // 1. Fresh install check (awaited - completes before continuing)
        await FreshInstallHandler().checkAndHandleFreshInstall()

        // 2. Wait for Core Data store to load
        await waitForCoreData()

        // 3. Restore auth session (after cleanup complete)
        AuthSession.shared.restorePreviousSignIn()

        // 4. Ready to show main UI
        isInitialized = true
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
