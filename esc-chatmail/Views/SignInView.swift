import SwiftUI
import GoogleSignIn

struct SignInView: View {
    @StateObject private var authSession = AuthSession.shared
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 20) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("ESC Chatmail")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("A chat-style Gmail client")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 16) {
                Button(action: signIn) {
                    HStack {
                        Image(systemName: "person.badge.key")
                        Text("Sign in with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isSigningIn)
                
                if isSigningIn {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 40)
        }
        .padding()
    }
    
    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            errorMessage = "Unable to get root view controller"
            isSigningIn = false
            return
        }
        
        Task {
            do {
                try await authSession.signIn(presenting: rootViewController)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSigningIn = false
                }
            }
        }
    }
}