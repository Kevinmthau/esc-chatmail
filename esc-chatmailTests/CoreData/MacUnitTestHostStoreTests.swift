#if os(macOS)
import CoreData
import XCTest
@testable import esc_chatmail

/// A Mac test host is the app itself, launched in the app's own sandbox container, so the default
/// Core Data store URL there is the mailbox of the Mac app the user runs. The host loads
/// `CoreDataStack.shared` at launch and every `TestCoreDataStack` reads its model, so that stack
/// must load a throwaway store instead (`CoreDataStack.makeUnitTestHostStoreURL()`).
///
/// Mac-only: on iOS the shared stack keeps the default URL, in a simulator's own container.
final class MacUnitTestHostStoreTests: XCTestCase {
    /// Revert-check: removing the `description?.url` assignment from the macOS branch of
    /// `CoreDataStack.persistentContainer` loads the store from
    /// `NSPersistentContainer.defaultDirectoryURL()`, the mailbox directory, which fails this.
    ///
    /// HONEST SCOPE: that revert was not run as written, because running it opens the mailbox
    /// this test protects. It was run with every store load removed as well, and there this
    /// fails only because nothing loaded. The next test is the one that run showed failing for
    /// the right reason.
    func testSharedStack_inAMacUnitTestHost_loadsAThrowawayStoreNotTheMailbox() throws {
        let container = CoreDataStack.shared.persistentContainer
        let loadedStoreURL = try XCTUnwrap(
            container.persistentStoreCoordinator.persistentStores.first?.url,
            "The shared stack's store should have loaded"
        )
        let storePath = loadedStoreURL.resolvingSymlinksInPath().path
        let mailboxDirectory = NSPersistentContainer.defaultDirectoryURL().resolvingSymlinksInPath().path
        let temporaryDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path

        XCTAssertFalse(
            storePath.hasPrefix(mailboxDirectory + "/"),
            "The test host opened a store in the app's mailbox directory: \(storePath)"
        )
        XCTAssertTrue(
            storePath.hasPrefix(temporaryDirectory + "/"),
            "Expected a store under the temporary directory, got \(storePath)"
        )
    }

    /// The description is what `resetStore()`, the backup manager and database maintenance read
    /// the store's location from, so it must name the throwaway store too.
    ///
    /// Revert-check: removing the `description?.url` assignment from the macOS branch of
    /// `CoreDataStack.persistentContainer` fails this: the description then names
    /// `Application Support/esc-chatmail/ESCChatmail.sqlite` in the app's container. Run with the
    /// store loads removed too, so that the check itself opened no store.
    func testSharedStack_inAMacUnitTestHost_describesTheStoreItLoaded() throws {
        let container = CoreDataStack.shared.persistentContainer
        let describedURL = try XCTUnwrap(container.persistentStoreDescriptions.first?.url)
        let mailboxDirectory = NSPersistentContainer.defaultDirectoryURL().resolvingSymlinksInPath().path

        XCTAssertFalse(describedURL.resolvingSymlinksInPath().path.hasPrefix(mailboxDirectory + "/"))
        XCTAssertEqual(
            container.persistentStoreCoordinator.persistentStores.first?.url?.resolvingSymlinksInPath().path,
            describedURL.resolvingSymlinksInPath().path
        )
    }
}
#endif
