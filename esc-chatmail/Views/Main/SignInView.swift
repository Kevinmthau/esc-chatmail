import SwiftUI
import GoogleSignIn

struct SignInView: View {
    @EnvironmentObject private var authSession: AuthSession
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var loginHint = ""
    
    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 20) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 80))
                    .symbolRenderingMode(.multicolor)
                    .foregroundColor(.blue)
                
                Text("ESC Chatmail")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("A chat-style Gmail client")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 16) {
                TextField("Google account email (optional)", text: $loginHint)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .disabled(isSigningIn)

                Text("If Google keeps reusing the wrong account, enter the address you want to connect before continuing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: signIn) {
                    HStack {
                        Image(systemName: "person.badge.key")
                        Text("Continue with Google")
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
                try await authSession.signIn(
                    presenting: rootViewController,
                    loginHint: loginHint
                )
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSigningIn = false
                }
            }
        }
    }
}
