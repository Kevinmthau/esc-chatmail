import Foundation

/// What a sign-out would end, as the user is told it: whether an account is signed in, and
/// the address the confirmation shows for it. `SettingsAppSignOutController` takes one when
/// it asks and another when the user answers, and `SettingsAppSignOutPolicy.answerStillApplies`
/// compares the two.
struct SettingsAppSignOutSubject: Equatable {
    let isAuthenticated: Bool
    /// `SettingsAppPreferences.displayedAccountEmail`: nil while nobody is signed in, and
    /// for a signed-in account with no address.
    let email: String?

    init(isAuthenticated: Bool, email: String?) {
        self.isAuthenticated = isAuthenticated
        self.email = email
    }

    /// `account` as it is now.
    @MainActor
    init(_ account: SettingsAppSignOutAccount) {
        let isAuthenticated = account.isAuthenticated
        self.init(
            isAuthenticated: isAuthenticated,
            email: SettingsAppPreferences.displayedAccountEmail(
                isAuthenticated: isAuthenticated,
                userEmail: account.userEmail
            )
        )
    }
}
