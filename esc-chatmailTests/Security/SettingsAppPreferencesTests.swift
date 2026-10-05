import XCTest
@testable import esc_chatmail

final class SettingsAppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var preferences: SettingsAppPreferences!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsAppPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = SettingsAppPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        preferences = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Sign Out request

    /// The Settings app does not register a bundle's defaults, so an untouched
    /// switch is an absent key, which must read as off.
    func testIsSignOutRequested_untouchedDefaults_returnsFalse() {
        XCTAssertFalse(preferences.isSignOutRequested)
    }

    func testIsSignOutRequested_settingsAppWroteTrue_returnsTrue() {
        defaults.set(true, forKey: SettingsAppPreferences.signOutRequestedKey)

        XCTAssertTrue(preferences.isSignOutRequested)
    }

    func testClearSignOutRequest_afterRequest_removesStoredValue() {
        defaults.set(true, forKey: SettingsAppPreferences.signOutRequestedKey)

        preferences.clearSignOutRequest()

        XCTAssertFalse(preferences.isSignOutRequested)
        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.signOutRequestedKey))
    }

    // MARK: - Published values

    func testPublishAccountEmail_email_storesItUnderSettingsKey() {
        preferences.publishAccountEmail("user@example.com")

        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.accountEmailKey), "user@example.com")
    }

    /// Removing (not blanking) the value lets the Settings row fall back to its
    /// "Not Signed In" default.
    func testPublishAccountEmail_nil_removesStoredValue() {
        preferences.publishAccountEmail("user@example.com")

        preferences.publishAccountEmail(nil)

        XCTAssertNil(defaults.object(forKey: SettingsAppPreferences.accountEmailKey))
    }

    func testPublishAppVersion_version_storesItUnderSettingsKey() {
        preferences.publishAppVersion("1.0 (1)")

        XCTAssertEqual(defaults.string(forKey: SettingsAppPreferences.versionKey), "1.0 (1)")
    }

    func testDisplayedAccountEmail_authenticated_returnsTrimmedEmail() {
        XCTAssertEqual(
            SettingsAppPreferences.displayedAccountEmail(isAuthenticated: true, userEmail: " user@example.com "),
            "user@example.com"
        )
    }

    /// Revert-check: dropping the `isAuthenticated` guard in
    /// `SettingsAppPreferences.displayedAccountEmail` makes this fail.
    func testDisplayedAccountEmail_signedOutWithLeftoverEmail_returnsNil() {
        XCTAssertNil(SettingsAppPreferences.displayedAccountEmail(isAuthenticated: false, userEmail: "user@example.com"))
    }

    func testDisplayedAccountEmail_authenticatedWithBlankEmail_returnsNil() {
        XCTAssertNil(SettingsAppPreferences.displayedAccountEmail(isAuthenticated: true, userEmail: "  "))
        XCTAssertNil(SettingsAppPreferences.displayedAccountEmail(isAuthenticated: true, userEmail: nil))
    }

    func testVersionDisplayString_shortVersionAndBuild_returnsCombined() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "7"]

        XCTAssertEqual(SettingsAppPreferences.versionDisplayString(infoDictionary: info), "1.0 (7)")
    }

    func testVersionDisplayString_missingBuild_returnsShortVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0"]

        XCTAssertEqual(SettingsAppPreferences.versionDisplayString(infoDictionary: info), "1.0")
    }

    func testVersionDisplayString_missingInfoDictionary_returnsUnknown() {
        XCTAssertEqual(SettingsAppPreferences.versionDisplayString(infoDictionary: nil), "Unknown")
    }

    // MARK: - Settings.bundle

    /// The bundle sits in a filesystem-synchronized group with no pbxproj
    /// entry of its own; this fails if the build stops copying it into the app
    /// as a bundle (e.g. flattened to a loose Root.plist), which would leave
    /// Settings → MushMail without the account or the Sign Out switch.
    func testSettingsBundle_appBundle_containsSettingsBundle() throws {
        let url = try settingsBundleURL()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("Root.plist").path))
    }

    /// The Settings app and the app meet only through these keys; a typo on
    /// either side silently disconnects the Sign Out switch.
    func testSettingsBundle_rootPlistKeys_matchPreferenceKeys() throws {
        let keys = Set(try preferenceSpecifiers().compactMap { $0["Key"] as? String })

        XCTAssertEqual(keys, [
            SettingsAppPreferences.accountEmailKey,
            SettingsAppPreferences.signOutRequestedKey,
            SettingsAppPreferences.versionKey
        ])
    }

    /// The switch must default to off, and title-value rows must carry a
    /// `DefaultValue` (the Settings app requires one to show the row).
    func testSettingsBundle_specifiers_haveRequiredDefaults() throws {
        let specifiers = try preferenceSpecifiers()

        let toggle = try XCTUnwrap(specifiers.first { $0["Key"] as? String == SettingsAppPreferences.signOutRequestedKey })
        XCTAssertEqual(toggle["Type"] as? String, "PSToggleSwitchSpecifier")
        XCTAssertEqual(toggle["DefaultValue"] as? Bool, false)

        let titleValueRows = specifiers.filter { $0["Type"] as? String == "PSTitleValueSpecifier" }
        XCTAssertEqual(titleValueRows.count, 2)
        for row in titleValueRows {
            XCTAssertNotNil(row["DefaultValue"] as? String, "row: \(row)")
        }
    }

    // MARK: - Helpers

    private func settingsBundleURL() throws -> URL {
        let candidateBundles = [Bundle(for: CoreDataStack.self), Bundle.main]
        return try XCTUnwrap(
            candidateBundles.lazy.compactMap {
                $0.url(forResource: "Settings", withExtension: "bundle")
            }.first,
            "Settings.bundle must be copied into the host app as a bundle"
        )
    }

    private func preferenceSpecifiers() throws -> [[String: Any]] {
        let rootURL = try settingsBundleURL().appendingPathComponent("Root.plist")
        let data = try Data(contentsOf: rootURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        return try XCTUnwrap(plist["PreferenceSpecifiers"] as? [[String: Any]])
    }
}
