import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var deps: Dependencies
    @State private var hasPerformedInitialSync = false
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        TabView {
            ConversationListView()
                .tabItem {
                    SwiftUI.Label("Chats", systemImage: "bubble.left.and.bubble.right")
                }
            
            InboxListView()
                .tabItem {
                    SwiftUI.Label("Inbox", systemImage: "tray")
                }
            
            SettingsView()
                .tabItem {
                    SwiftUI.Label("Settings", systemImage: "gear")
                }
        }
        .onAppear {
            guard !hasPerformedInitialSync else { return }
            hasPerformedInitialSync = true
            syncTask = Task {
                do {
                    try await deps.syncEngine.performInitialSync()
                } catch {
                    Log.error("Initial sync error", category: .sync, error: error)
                }
            }
        }
        .onDisappear {
            syncTask?.cancel()
        }
    }
}