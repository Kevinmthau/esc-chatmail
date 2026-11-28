import CoreData
import XCTest
@testable import esc_chatmail

/// What the app declares about protection and privileges, pinned so that a capability, an
/// entitlement or a plist key changed in Xcode shows up as a failing test rather than in the field
/// (architecture review 2026-11, `security-privacy#6`). The plists and entitlement files are read
/// from the repository and parsed; the store option is read off a description the app configures.
final class PrivilegeDeclarationsTests: XCTestCase {
    private func plist(_ path: String) throws -> [String: Any] {
        let data = try XCTUnwrap(try repositorySource(path).data(using: .utf8))
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "\(path) is not a dictionary"
        )
    }

    // MARK: - Data protection

    #if os(iOS)
    /// The iOS store is opened as complete until first user authentication, so that a background
    /// task on a locked phone (after the first unlock) can read and write it. (The suite is not in
    /// `Mac.xctestplan`; the Mac's store has no protection classes.)
    ///
    /// Revert-check: removing the `setOption` in `CoreDataStack.applyFileProtection(to:)` fails
    /// this.
    func testStoreDescription_iOSFileProtection_isCompleteUntilFirstUserAuthentication() {
        let description = NSPersistentStoreDescription()
        CoreDataStack.applyFileProtection(to: description)
        XCTAssertEqual(
            description.options[NSPersistentStoreFileProtectionKey] as? String,
            FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        )
    }

    /// The store the app has open carries the class: the iOS test host loads
    /// `CoreDataStack.shared` synchronously, and a store's options are the ones it was added with,
    /// so this reads what the production container did, not its source (a commented-out call, or
    /// one moved after the load, would leave the source looking right).
    ///
    /// Revert-check: removing `Self.applyFileProtection(to: description)` from
    /// `CoreDataStack.persistentContainer`, or moving it after `loadPersistentStores(for:)`, fails
    /// this.
    func testPersistentContainer_loadedStore_hasTheFileProtection() throws {
        let store = try XCTUnwrap(
            CoreDataStack.shared.persistentContainer.persistentStoreCoordinator.persistentStores.first,
            "The test host's shared store is attached"
        )
        XCTAssertEqual(
            store.options?[NSPersistentStoreFileProtectionKey] as? String,
            FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        )
    }
    #endif

    /// No default data-protection class is declared for the iOS app, or only the same class the
    /// store names: Xcode's Data Protection capability defaults to Complete, which would lock every
    /// mail file (bodies, attachments, the store's own files) away from background sync on a
    /// locked phone.
    func testIOSEntitlements_declareNoStricterDefaultDataProtection() throws {
        let entitlements = try plist("esc-chatmail/Resources/esc_chatmail.entitlements")
        if let protection = entitlements["com.apple.developer.default-data-protection"] {
            XCTAssertEqual(
                protection as? String,
                "NSFileProtectionCompleteUntilFirstUserAuthentication",
                "A stricter default class locks the mailbox away from locked-device background sync"
            )
        }
    }

    // MARK: - Push

    /// Nothing registers for remote notifications (`docs/mac-app-plan.md` recorded the push
    /// entitlement as unused), so the iOS app asks for no push entitlement and no
    /// remote-notification background mode. The background modes it does use stay, and so does
    /// every BGTask identifier, the retired vacuum one included: BGTaskScheduler raises on a
    /// request whose identifier has no entry, and a device that ran an earlier build can hold one.
    ///
    /// Revert-check: putting `aps-environment` back in `esc_chatmail.entitlements`, or
    /// `remote-notification` back in `UIBackgroundModes`, fails this.
    @MainActor
    func testIOSApp_declaresNoPushPrivilege_andKeepsItsBackgroundTasks() throws {
        let entitlements = try plist("esc-chatmail/Resources/esc_chatmail.entitlements")
        XCTAssertNil(entitlements["aps-environment"])

        let info = try plist("esc-chatmail/Resources/Info.plist")
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["fetch", "processing"])
        let identifiers = try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        XCTAssertTrue(identifiers.contains(DatabaseMaintenanceService.retiredVacuumTaskIdentifier))
        XCTAssertEqual(identifiers.count, 5)

        let code = try repositorySwiftFilePaths(under: "esc-chatmail").map { try repositorySource($0) }
        XCTAssertFalse(
            code.contains { $0.contains("registerForRemoteNotifications") },
            "Something registers for remote notifications; it needs the push entitlement back"
        )
    }

    // MARK: - App Transport Security

    /// Neither app declares `NSAllowsLocalNetworking`. ATS has exempted IP literals, unqualified
    /// names and `.local` since iOS 10 and macOS 10.12, so the key granted nothing: measured on the
    /// iOS 27.0 simulator with it gone from the built Info.plist, a plain-http request to
    /// `127.0.0.1` and to `localhost` still reached a loopback listener. Arbitrary loads stay off
    /// for the app's own requests and on for web content, as before.
    ///
    /// Revert-check: putting `NSAllowsLocalNetworking` back in either plist fails this.
    func testATS_declaresNoLocalNetworkingException_andKeepsItsOtherKeys() throws {
        for path in ["esc-chatmail/Resources/Info.plist", "esc-chatmail/Resources/Info-macOS.plist"] {
            let ats = try XCTUnwrap(try plist(path)["NSAppTransportSecurity"] as? [String: Any], path)
            XCTAssertNil(ats["NSAllowsLocalNetworking"], path)
            XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, false, path)
            XCTAssertEqual(ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool, true, path)
        }
    }
}
