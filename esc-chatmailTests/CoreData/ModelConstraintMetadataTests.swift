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

    /// The real drift tripwire: replays the production runtime mutation
    /// (`CoreDataStack.enforceUniquenessConstraints`, which is skipped under
    /// XCTest) against a freshly loaded copy of the bundled model and asserts
    /// it changes nothing. If the declared constraint ever leaves the
    /// .xcdatamodel while the runtime append remains, the mutated model's
    /// version hash diverges here — the exact divergence that would strand
    /// production store metadata with no matching bundled model.
    ///
    /// Mirrors the production guard verbatim; simplify to constraint-presence
    /// only once the runtime mutation is deleted. Fresh model copies stay
    /// inside an autoreleasepool and never touch entity classes, per the
    /// single-model-per-process rule (see TestCoreDataStack).
    func testRuntimeConstraintMutationIsANoOpOnTheBundledModel() throws {
        try autoreleasepool {
            let momdURL = try XCTUnwrap(
                Bundle(for: CoreDataStack.self).url(forResource: "ESCChatmail", withExtension: "momd")
            )
            let currentModelURL = momdURL.appendingPathComponent("ESCChatmail 2.mom")
            let rawModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: currentModelURL))
            let mutatedModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: currentModelURL))

            let rawMessage = try XCTUnwrap(rawModel.entitiesByName["Message"])
            let mutatedMessage = try XCTUnwrap(mutatedModel.entitiesByName["Message"])

            // Production logic, replicated: append ["id"] unless already present.
            let constraint: [String] = ["id"]
            let guardMatched = mutatedMessage.uniquenessConstraints
                .contains(where: { ($0 as? [String]) == constraint })
            if !guardMatched {
                mutatedMessage.uniquenessConstraints.append(constraint as [Any])
            }

            XCTAssertTrue(
                guardMatched,
                "The runtime mutation's guard no longer matches the declared constraint — " +
                "production would append a duplicate and change every store's version hash"
            )
            XCTAssertEqual(
                rawMessage.versionHash, mutatedMessage.versionHash,
                "The effective production model diverges from the bundled model — " +
                "existing stores would hit NSMigrationMissingSourceModelError on the next " +
                "model version, which the recovery ladder answers by deleting the store"
            )
        }
    }
}
