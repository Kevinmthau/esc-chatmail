import Foundation

/// The account side of a Settings-app sign-out (`SettingsAppSignOutController`):
/// what the request is judged against and the sign-out it runs. `AuthSession`
/// is the only production conformer; tests substitute a fake so the
/// controller's choice of signal is exercised without a real session.
@MainActor
protocol SettingsAppSignOutAccount: AnyObject {
    var isAuthenticated: Bool { get }
    var userEmail: String? { get }
    /// See `AuthSession.isDurablySignedOut()`. Called only while a request is
    /// pending: while signed out it reads the keychain.
    func isDurablySignedOut() -> Bool
    /// See `AuthSession.signOut()`: false only when cleanup never began.
    func signOut() async -> Bool
}

extension AuthSession: SettingsAppSignOutAccount {}
