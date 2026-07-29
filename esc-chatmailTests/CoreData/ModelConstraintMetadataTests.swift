import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the Core Data model/metadata facts the sync-reliability work depends on.
///
/// The uniqueness constraints are declared IN the versioned .xcdatamodel (since
/// 2025-09), so the app's runtime `enforceUniquenessConstraints` mutation has
/// always been a no-op: its guard finds the constraint already present and
/// returns without touching the model. These tests are the tripwire for that
/// premise — if the declared constraint ever left the model while the runtime
/// mutation remained, production store metadata would diverge from every
/// bundled model, and the next model version would fail lightweight migration
/// with NSMigrationMissingSourceModelError, which the recovery ladder currently
/// answers by deleting the store.
final class ModelConstraintMetadataTests: XCTestCase {

    /// The process-wide shared model (see TestCoreDataStack.sharedModel — one
    /// model instance per process).
    private var sharedModel: NSManagedObjectModel {
        CoreDataStack.shared.persistentContainer.managedObjectModel
    }

    func testMessageIdUniquenessConstraintIsDeclaredInTheModel() throws {
        let message = try XCTUnwrap(sharedModel.entitiesByName["Message"])

        // Match the exact form of the production guard in
        // CoreDataStack.enforceUniquenessConstraints: the loaded model presents
        // constraint tuples as [String], so `($0 as? [String]) == ["id"]` is
        // precisely the check that makes the runtime mutation a no-op.
        XCTAssertTrue(
            message.uniquenessConstraints.contains(where: { ($0 as? [String]) == ["id"] }),
            "Message.id uniqueness constraint must stay declared in the .xcdatamodel; " +
            "if it moves out while the runtime mutation exists, store metadata diverges " +
            "from every bundled model and the next model version wipes upgrading stores"
        )
        XCTAssertEqual(
            message.uniquenessConstraints.count, 1,
            "A second Message constraint would change version hashes for every existing store"
        )
    }

    func testAbandonedSyncMessageUniquenessConstraintIsDeclaredInTheModel() throws {
        let abandoned = try XCTUnwrap(sharedModel.entitiesByName["AbandonedSyncMessage"])
        XCTAssertTrue(
            abandoned.uniquenessConstraints.contains(where: { ($0 as? [String]) == ["gmailMessageId"] })
        )
    }

    /// A store created from the shared model must report metadata compatible
    /// with that same model. This is the drift tripwire: production loads
    /// stores with the (currently no-op) runtime-mutated model, so any change
    /// that makes the effective production model differ from the bundled one
    /// shows up here as an incompatibility — the precondition for a
    /// missing-source-model migration failure on the next model version.
    func testFreshSqliteStoreMetadataIsCompatibleWithBundledModel() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let coordinator = try XCTUnwrap(stack.persistentContainer.persistentStoreCoordinator)
        let store = try XCTUnwrap(coordinator.persistentStores.first)

        let metadata = coordinator.metadata(for: store)
        XCTAssertTrue(
            sharedModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
            "Store metadata no longer matches the bundled model — lightweight migration " +
            "would fail to locate a source model for existing stores"
        )
    }
}
