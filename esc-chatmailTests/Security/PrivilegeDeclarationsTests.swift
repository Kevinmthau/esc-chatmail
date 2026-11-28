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

    /// The iOS store is opened as complete until first user authentication, so that a background
    /// task on a locked phone (after the first unlock) can read and write it.
    ///
    /// Revert-check: removing the `setOption` in `CoreDataStack.applyFileProtection(to:)` fails
    /// this on iOS.
    func testStoreDescription_iOSFileProtection_isCompleteUntilFirstUserAuthentication() {
        let description = NSPersistentStoreDescription()
        CoreDataStack.applyFileProtection(to: description)
        #if os(iOS)
        XCTAssertEqual(
            description.options[NSPersistentStoreFileProtectionKey] as? String,
            FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        )
        #else
        XCTAssertTrue(description.options.isEmpty, "The Mac's store has no protection classes")
        #endif
    }

    /// The production container is configured through it.
    ///
    /// Revert-check: removing `Self.applyFileProtection(to: description)` from
    /// `CoreDataStack.persistentContainer` fails this.
    func testPersistentContainer_appliesTheFileProtection() throws {
        let source = try repositorySource("esc-chatmail/Services/CoreData/CoreDataStack.swift")
        XCTAssertTrue(source.contains("Self.applyFileProtection(to: description)"))
    }

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
}
