import XCTest
@testable import esc_chatmail

/// HONEST SCOPE: that `esc_chatmailApp.init` starts the shared publisher on
/// every launch, background launches included, is app wiring the unit-test
/// host deliberately skips; these drive a publisher over an isolated session.
@MainActor
final class SettingsAppAccountPublisherTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var authDefaults: UserDefaults!
    private var preferences: SettingsAppPreferences!
    private var authSession: AuthSession!
    private var publisher: SettingsAppAccountPublisher!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsAppAccountPublisherTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        authDefaults = UserDefaults(suiteName: "\(suiteName!).auth")!
        preferences = SettingsAppPreferences(defaults: defaults)
        authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: authDefaults,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        publisher = SettingsAppAccountPublisher()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        authDefaults.removePersistentDomain(forName: "\(suiteName!).auth")
        publisher = nil
        authSession = nil
        preferences = nil
        authDefaults = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStart_signedInSession_publishesAccountAndVersion() {
        authSession.userEmail = "user@example.com"
        authSession.isAuthenticated = true

        publisher.start(
            observing: authSession,
            preferences: preferences,
            infoDictionary: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "9"]
        )

        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.accountEmailKey), "user@example.com")
        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.versionKey), "2.1 (9)")
    }

    /// A session published after launch (restore or sign-in) reaches the
    /// Settings app without any view mounted.
    func testStart_sessionPublishedLater_publishesAccount() {
        publisher.start(observing: authSession, preferences: preferences, infoDictionary: nil)
        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.accountEmailKey))

        authSession.userEmail = "user@example.com"
        authSession.isAuthenticated = true

        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.accountEmailKey), "user@example.com")
    }

    /// A session dropped with no view mounted (a background launch's rejected
    /// restore clears `userEmail` then `isAuthenticated`) must not leave
    /// Settings naming the dropped account.
    ///
    /// Revert-check: removing the `$isAuthenticated` / `$userEmail`
    /// subscription from `SettingsAppAccountPublisher.start` makes this fail.
    func testStart_sessionDropped_removesAccount() {
        authSession.userEmail = "user@example.com"
        authSession.isAuthenticated = true
        publisher.start(observing: authSession, preferences: preferences, infoDictionary: nil)
        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.accountEmailKey), "user@example.com")

        authSession.userEmail = nil
        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.accountEmailKey))
        authSession.isAuthenticated = false
        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.accountEmailKey))
    }

    /// `isAuthenticated` dropping first must clear the row too, though the
    /// leftover `userEmail` still names the account.
    func testStart_authenticationDroppedBeforeEmail_removesAccount() {
        authSession.userEmail = "user@example.com"
        authSession.isAuthenticated = true
        publisher.start(observing: authSession, preferences: preferences, infoDictionary: nil)
        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.accountEmailKey), "user@example.com")

        authSession.isAuthenticated = false

        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.accountEmailKey))
    }
}
