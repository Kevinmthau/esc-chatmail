import XCTest
import CoreData
@testable import esc_chatmail

/// Two lookups that read their table from one end until model 8 gave them an index, on a
/// real SQLite store. In the default plan, unlike `ScaleQueryPlanTests`: each asserts an
/// indexed search against a whole-table read, never a choice between two indexes. The
/// conversation lookup is an equality on the one indexed column; the attachment check is
/// an `OR` of two `IN`s, whose two-index plan is a cost choice SQLite's no-statistics
/// defaults make lopsidedly.
final class ModelV8IndexPlanTests: XCTestCase {
    /// A conversation looked up by its UUID (`ConversationPredicates.id`, and the many
    /// call sites that spell `id == %@` themselves: the page loader's first lookup, send
    /// anchoring, launch repairs) searches `byConversationIdIndex`. Before model 8
    /// `ZCONVERSATION.ZID` had no index, and each lookup read every conversation.
    ///
    /// HONEST SCOPE: no line of production code reverts this; a model version that drops
    /// the index does.
    func testConversationLookupByUUID_searchesTheIDIndex() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext
        let wanted = UUID()
        try context.performAndWait {
            ConversationBuilder().withId(wanted).build(in: context)
            ConversationBuilder().build(in: context)
            try context.save()
            context.reset()
        }

        var found: [UUID] = []
        let plans = try SQLiteQueryPlanRecorder.record {
            found = try context.performAndWait {
                let request = NSFetchRequest<Conversation>(entityName: "Conversation")
                request.predicate = ConversationPredicates.id(wanted)
                return try context.fetch(request).map(\.id)
            }
        }

        XCTAssertEqual(found, [wanted])
        // Asked for by its SQL: a recording is of the whole process, and a task an
        // earlier test left can add a fetch of its own.
        let plan = try XCTUnwrap(
            plans.first { $0.reads("ZCONVERSATION") && $0.sql.contains("ZID =") },
            "\(plans)"
        )
        XCTAssertEqual(plan.scans(of: "ZCONVERSATION"), [], "\(plan)")
        XCTAssertTrue(
            plan.indexes(on: "ZCONVERSATION").contains("Z_Conversation_byConversationIdIndex"),
            "\(plan)"
        )
    }

    /// Before an attachment file is removed, the store is asked whether a row still names it
    /// as its file or its preview (`DeletedRowFileReclamation.referencedAttachmentPaths`,
    /// once for each 200 paths of a purge). Model 8's two path indexes make that two index
    /// searches; before it, each question read ZATTACHMENT from one end.
    ///
    /// HONEST SCOPE: no line of production code reverts this; a model version that drops
    /// either index, or a predicate no longer an `IN` over each column, does.
    func testReferencedAttachmentPaths_searchTheTwoPathIndexes() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let context = stack.viewContext
        try context.performAndWait {
            let message = MessageBuilder().withId("v8-plan-message").build(in: context)
            AttachmentBuilder()
                .withLocalURL("attachments/v8/a.pdf")
                .withPreviewURL("previews/v8/a.jpg")
                .forMessage(message)
                .build(in: context)
            AttachmentBuilder()
                .withLocalURL("attachments/v8/b.pdf")
                .forMessage(message)
                .build(in: context)
            try context.save()
            context.reset()
        }

        var referenced: Set<String> = []
        let plans = try SQLiteQueryPlanRecorder.record {
            referenced = try DeletedRowFileReclamation.referencedAttachmentPaths(
                among: ["attachments/v8/b.pdf", "previews/v8/a.jpg", "attachments/v8/gone.pdf"],
                in: context
            )
        }

        XCTAssertEqual(referenced, ["attachments/v8/b.pdf", "previews/v8/a.jpg"])
        let plan = try XCTUnwrap(
            plans.first { $0.reads("ZATTACHMENT") && $0.sql.contains("ZLOCALURL IN") },
            "\(plans)"
        )
        XCTAssertEqual(plan.scans(of: "ZATTACHMENT"), [], "\(plan)")
        XCTAssertEqual(
            Set(plan.indexes(on: "ZATTACHMENT")),
            ["Z_Attachment_byLocalURLIndex", "Z_Attachment_byPreviewURLIndex"],
            "\(plan)"
        )
    }
}
