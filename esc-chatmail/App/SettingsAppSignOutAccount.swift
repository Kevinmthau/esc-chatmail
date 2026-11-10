import Foundation

/// The account side of a Settings-app sign-out (`SettingsAppSignOutController`):
/// what the request is judged against and the sign-out it runs. `AuthSession`
/// is the only production conformer; tests substitute a fake so the
/// controller's choice of signal is exercised without a real session.
@MainActor
protocol SettingsAppSignOutAccount: AnyObject {
    var isAuthenticated: Bool { get }
    var userEmail: String? { get }
    /// See `AuthSession.isDurablySignedOut()`. While signed out it reads the
    /// keychain, so it is called only to judge a request (a pending Settings-app
    /// one, or the Mac's menu command being chosen) and, on the Mac, to renew
    /// whether that command has an account to sign out
    /// (`SettingsAppSignOutController.refreshHeldAccount`).
    func isDurablySignedOut() -> Bool
    /// See `AuthSession.signOut()`: false only when cleanup never began.
    func signOut() async -> Bool
}

extension AuthSession: SettingsAppSignOutAccount {}
