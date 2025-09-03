import SwiftUI

struct MainTabView: View {
    @StateObject private var syncEngine = SyncEngine.shared
    
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
            performInitialSync()
        }
    }
    
    private func performInitialSync() {
        Task {
            do {
                try await syncEngine.performInitialSync()
            } catch {
                print("Initial sync error: \(error)")
            }
        }
    }
}