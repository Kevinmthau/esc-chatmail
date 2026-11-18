import CoreData
import XCTest
@testable import esc_chatmail

/// The name a conversation's row shows, as the lists' questions about a row read it
/// (`ConversationRowView.displayedName`): the participants' names from the rollup cache the row
/// filled, and otherwise the row's fallback, never the stored title alone where the row shows
/// something else.
///
/// The loader gets a resolver that knows nobody, so names come from the stored `Person` rows;
/// the row's own load is made here with the row's arguments.
///
/// HONEST SCOPE: no row is drawn. That the drawn row shows this same name rests on the row's
/// body calling the same static lookups (`ConversationRowView`'s `cachedParticipantInfo` and
/// `fallbackDisplayName` forward to them).
@MainActor
final class ConversationRowDisplayedNameTests: XCTestCase {
    private static let myEmail = "me@example.com"

    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    /// Revert-check: making `ConversationRowView.displayedName` return the fallback alone
    /// (ignoring the cached participant info) makes this fail once the row's load has landed.
    func testDisplayedName_afterTheRowsLoad_isTheLoadedNameNotTheStoredTitle() async throws {
        let loader = makeLoader()
        let person = PersonBuilder()
            .withEmail("ada@example.com")
            .withDisplayName("Ada Lovelace")
            .build(in: context)
        let conversation = ConversationBuilder()
            .withDisplayName("Stored Title")
            // Unique per test: the hash is part of the rollup cache's key.
            .withParticipantHash("p|\(UUID().uuidString)")
            .withParticipant(person)
            .visible()
            .recentlyActive()
            .build(in: context)
        try context.save()
        let snapshot = ConversationSnapshot(from: conversation)

        XCTAssertEqual(displayedName(of: snapshot, loader: loader), "Stored Title", "Before the row's load")

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: Self.myEmail,
            maxParticipants: 4,
            participantHash: snapshot.participantHash,
            fallbackDisplayName: snapshot.displayNameHint
        )

        XCTAssertNotEqual(info.formattedDisplayName, "Stored Title", "The fixture must make the two differ")
        XCTAssertEqual(displayedName(of: snapshot, loader: loader), info.formattedDisplayName)
    }

    /// A row with no stored title shows its participants' addresses, and so does the question.
    ///
    /// Revert-check: making `ConversationRowView.displayedName` read `snapshot.displayNameHint`
    /// as its fallback makes this fail: the name is empty.
    func testDisplayedName_noStoredTitleAndNothingLoaded_isTheRowsAddressFallback() throws {
        let person = PersonBuilder().withEmail("ada@example.com").build(in: context)
        let conversation = ConversationBuilder()
            .withParticipantHash("p|\(UUID().uuidString)")
            .withParticipant(person)
            .visible()
            .recentlyActive()
            .build(in: context)
        conversation.displayName = nil
        try context.save()
        let snapshot = ConversationSnapshot(from: conversation)

        let name = displayedName(of: snapshot, loader: makeLoader())

        XCTAssertEqual(
            name,
            PersonDisplayNameResolver.displayFallbackConversationName(
                hint: nil,
                participantEmails: ["ada@example.com"]
            )
        )
        XCTAssertFalse(name.isEmpty)
    }

    // MARK: - Helpers

    private func displayedName(of snapshot: ConversationSnapshot, loader: ParticipantLoader) -> String {
        ConversationRowView.displayedName(
            snapshot: snapshot,
            conversationObjectID: snapshot.objectID,
            currentUserEmail: Self.myEmail,
            participantLoader: loader
        )
    }

    private func makeLoader() -> ParticipantLoader {
        let myEmail = Self.myEmail
        return ParticipantLoader(
            contactsResolver: NobodyContactsResolver(),
            currentUserAliasesProvider: { _, _ in [myEmail] },
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )
    }
}
