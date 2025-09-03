import SwiftUI

struct SettingsView: View {
    @StateObject private var authSession = AuthSession.shared
    @StateObject private var syncEngine = SyncEngine.shared
    @State private var showingSignOutConfirmation = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = authSession.userEmail {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                            
                            VStack(alignment: .leading) {
                                Text(email)
                                    .font(.headline)
                                Text("Signed in")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    Button(action: { showingSignOutConfirmation = true }) {
                        HStack {
                            Image(systemName: "arrow.right.square")
                            Text("Sign Out")
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section("Sync") {
                    if syncEngine.isSyncing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(syncEngine.syncStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: syncEngine.syncProgress)
                    } else {
                        Button(action: performFullSync) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Perform Full Sync")
                            }
                        }
                        
                        Button(action: performIncrementalSync) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Check for Updates")
                            }
                        }
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text("com.esc.InboxChat")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Sign Out",
                isPresented: $showingSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out?")
            }
        }
    }
    
    private func signOut() {
        authSession.signOut()
    }
    
    private func performFullSync() {
        Task {
            do {
                try await syncEngine.performInitialSync()
            } catch {
                print("Full sync error: \(error)")
            }
        }
    }
    
    private func performIncrementalSync() {
        Task {
            do {
                try await syncEngine.performIncrementalSync()
            } catch {
                print("Incremental sync error: \(error)")
            }
        }
    }
}