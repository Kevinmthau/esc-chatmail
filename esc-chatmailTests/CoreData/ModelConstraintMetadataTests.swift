import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the Core Data model/metadata facts the sync-reliability work depends on.
///
/// The uniqueness constraints are declared IN the versioned .xcdatamodel (since
/// 2025-09). The runtime `enforceUniquenessConstraints` mutation that once
/// shadowed the Message.id constraint was deleted with model v3 (it was born a
/// no-op); model changes belong in versioned model files only. These tests
/// remain the tripwire for the declared constraints: silently dropping one
/// changes entity version hashes for every existing store, and reintroducing
/// any runtime model mutation re-arms the missing-source-model wipe.
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

    /// New v3 entity: SyncCheckpoint may carry constraints from birth (the
    /// no-constraints-on-existing-entities-until-v4 rule applies to entities
    /// with existing rows, which a brand-new entity has none of).
    func testSyncCheckpointKindUniquenessConstraintIsDeclaredInTheModel() throws {
        let checkpoint = try XCTUnwrap(sharedModel.entitiesByName["SyncCheckpoint"])
        XCTAssertTrue(
            checkpoint.uniquenessConstraints.contains(where: { ($0 as? [String]) == ["kind"] }),
            "kind's uniqueness is what makes checkpoint writes natural upserts"
        )
    }

    /// No entity outside the declared set may carry constraints, and no
    /// pre-v3 entity may gain one before the v4-after-repair-soaks gate
    /// (adding a constraint changes the entity's version hash AND makes
    /// existing duplicate rows a migration-time constraint violation).
    func testNoUndeclaredUniquenessConstraintsExist() {
        let constrained = sharedModel.entities
            .filter { !$0.uniquenessConstraints.isEmpty }
            .compactMap { $0.name }
            .sorted()
        XCTAssertEqual(
            constrained, ["AbandonedSyncMessage", "Message", "SyncCheckpoint"],
            "A constraint appeared on or vanished from an unexpected entity — " +
            "pre-v3 entities must not gain constraints until v4, after dedup repairs soak"
        )
    }
}
