import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authSession: AuthSession
    @State private var showingSignOutConfirmation = false
    @State private var isSigningOut = false

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
                            if isSigningOut {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                Text("Signing Out...")
                            } else {
                                Image(systemName: "arrow.right.square")
                                Text("Sign Out")
                            }
                        }
                        .foregroundColor(.red)
                    }
                    .disabled(isSigningOut)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(Bundle.main.bundleIdentifier ?? "Unknown")
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
        isSigningOut = true
        Task {
            await authSession.signOut()
            // isSigningOut will reset when view is replaced by SignInView
        }
    }
}