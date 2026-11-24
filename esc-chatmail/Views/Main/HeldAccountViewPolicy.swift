import Foundation

/// The words and symbol of `HeldAccountView`, the screen shown over an account whose
/// launch restore could not finish (`HeldAccount`).
///
/// It must not read as signed out: the mail is on the device, and the account comes
/// back by itself (`LaunchRestoreRetryCoordinator`). Before it existed this state showed
/// the first-run "A chat-style Gmail client" and "Continue with Google".
enum HeldAccountViewPolicy {
    static func title(for failure: HeldAccount.Failure) -> String {
        switch failure {
        case .cannotConnect:
            return "Can’t Connect to Google"
        case .couldNotRestore:
            return "Can’t Open Your Account"
        }
    }

    static func message(for heldAccount: HeldAccount) -> String {
        let mail = heldAccount.email.map { "Your mail for \($0)" } ?? "Your mail"
        switch heldAccount.failure {
        case .cannotConnect:
            return "\(mail) is still on this device. MushMail will reconnect as soon as it can reach Google."
        case .couldNotRestore:
            return "\(mail) is still on this device. MushMail will try again shortly."
        }
    }

    static func systemImage(for failure: HeldAccount.Failure) -> String {
        switch failure {
        case .cannotConnect:
            return "wifi.exclamationmark"
        case .couldNotRestore:
            return "exclamationmark.triangle"
        }
    }

    static let retryTitle = "Try Again"
    static let retryingTitle = "Connecting…"
    /// The way out when retrying will not help: Google's sign-in, for the held address.
    static let signInAgainTitle = "Sign In Again"
}
