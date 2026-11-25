import SwiftUI

/// Shown by `ContentView` in place of `SignInView` while an account is held
/// (`AuthSession.heldAccount`): the launch restore kept the account but could not finish,
/// most often because Google could not be reached.
///
/// Try Again runs the launch's restore again (`LaunchRestoreRetryCoordinator.retryNow()`),
/// which also runs by itself when the network returns and when the app comes to the
/// foreground. Sign In Again is Google's sign-in with the held address as the hint, for
/// the case retrying cannot mend: a different address there replaces this mailbox, as a
/// sign-in with another account always does.
struct HeldAccountView: View {
    let heldAccount: HeldAccount
    @ObservedObject var retryCoordinator: LaunchRestoreRetryCoordinator
    @EnvironmentObject private var authSession: AuthSession
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Image(systemName: HeldAccountViewPolicy.systemImage(for: heldAccount.failure))
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(HeldAccountViewPolicy.title(for: heldAccount.failure))
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(HeldAccountViewPolicy.message(for: heldAccount))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button(action: retryCoordinator.retryNow) {
                    HStack(spacing: 8) {
                        if retryCoordinator.isRestoring {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            retryCoordinator.isRestoring
                                ? HeldAccountViewPolicy.retryingTitle
                                : HeldAccountViewPolicy.retryTitle
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(retryCoordinator.isRestoring || isSigningIn)

                Button(HeldAccountViewPolicy.signInAgainTitle, action: signInAgain)
                    .buttonStyle(.borderless)
                    .disabled(retryCoordinator.isRestoring || isSigningIn)

                if isSigningIn {
                    ProgressView()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 360)
        }
        .padding(40)
    }

    private func signInAgain() {
        isSigningIn = true
        errorMessage = nil

        guard let presentationAnchor = PresentationAnchorLookup.signInAnchor() else {
            errorMessage = "Unable to get root view controller"
            isSigningIn = false
            return
        }

        Task {
            do {
                try await authSession.signIn(
                    presenting: presentationAnchor,
                    loginHint: heldAccount.email
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
