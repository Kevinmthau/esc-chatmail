import XCTest
import CoreData
@testable import esc_chatmail

/// A group's participants are shown in one order, ascending by normalized
/// email address (`ConversationParticipantExtractor.participantsInDisplayOrder`),
/// in the loaded title, the avatar stack and the stored
/// `Conversation.displayName`. Before, each of them walked
/// `Conversation.participants` as Core Data handed it over, so one saved group
/// read "Grace, Ada, Alan" on one load and "Alan, Ada, Grace" on the next.
///
/// Every context here is a background context entered through `performAndWait`,
/// or a main-queue context used from the main actor (the one loader test), so
/// no access is off-queue. The helpers are static so those blocks capture no
/// test case.
///
/// HONEST SCOPE: nothing can force the order a `Set` of managed objects
/// iterates in, so the four tests that load a saved group fail against the old
/// code by measurement, not by construction. They pass there only if every one
/// of their loads happens to come out in ascending address order, one order in
/// 40,320 for eight people; with the old walk put back, each failed 20 runs
/// out of 20. The two `testParticipantsInDisplayOrder_…` tests hand the
/// ordering an array, whose order is fixed, and fail by construction.
final class ConversationParticipantDisplayOrderTests: XCTestCase {
    private static let myEmail = "me@example.com"
    private static let loadCount = 25

    /// In the order the rows are inserted, which is neither ascending nor
    /// descending by address.
    private static let people: [(email: String, name: String)] = [
        ("grace@example.com", "Grace Hopper"),
        ("ada@example.com", "Ada Lovelace"),
        ("margaret@example.com", "Margaret Hamilton"),
        ("alan@example.com", "Alan Turing"),
        ("katherine@example.com", "Katherine Johnson"),
        ("edsger@example.com", "Edsger Dijkstra"),
        ("barbara@example.com", "Barbara Liskov"),
        ("donald@example.com", "Donald Knuth")
    ]

    private static let orderedEmails = [
        "ada@example.com",
        "alan@example.com",
        "barbara@example.com",
        "donald@example.com",
        "edsger@example.com",
        "grace@example.com",
        "katherine@example.com",
        "margaret@example.com"
    ]

    private static let orderedNames = [
        "Ada Lovelace",
        "Alan Turing",
        "Barbara Liskov",
        "Donald Knuth",
        "Edsger Dijkstra",
        "Grace Hopper",
        "Katherine Johnson",
        "Margaret Hamilton"
    ]

    private static let orderedFirstNames = [
        "Ada", "Alan", "Barbara", "Donald", "Edsger", "Grace", "Katherine", "Margaret"
    ]

    // MARK: - The ordering itself

    /// Revert-check: the `.sorted` in
    /// `ConversationParticipantExtractor.participantsInDisplayOrder` (without it
    /// the rows come back as given). With the key's normalized address replaced
    /// by the stored one, `Bob@Example.com` and `a.z@gmail.com` move to the
    /// front.
    func testParticipantsInDisplayOrder_rowsInAnyOrder_returnsAscendingNormalizedAddress() {
        let context = TestCoreDataStack().newBackgroundContext()
        context.performAndWait {
            let rows = [
                "zed@example.com",
                "Bob@Example.com",
                "a.z@gmail.com",
                "ab@gmail.com",
                "alice@example.com"
            ].map { Self.makeRow(email: $0, name: "Someone", in: context) }

            // By normalized address: ab@gmail.com, alice@example.com,
            // az@gmail.com (Gmail ignores the dot), bob@example.com,
            // zed@example.com.
            let expected = [
                "ab@gmail.com",
                "alice@example.com",
                "a.z@gmail.com",
                "Bob@Example.com",
                "zed@example.com"
            ]

            XCTAssertEqual(
                ConversationParticipantExtractor.participantsInDisplayOrder(rows).map { $0.person?.email },
                expected
            )
            XCTAssertEqual(
                ConversationParticipantExtractor.participantsInDisplayOrder(rows.reversed()).map { $0.person?.email },
                expected
            )
        }
    }

    /// Revert-check: the stored address and the stored name in
    /// `ParticipantDisplayOrderKey`'s `<`. Compared by normalized address alone,
    /// the three rows for Ada are equal and come back in the order given.
    func testParticipantsInDisplayOrder_rowsSharingOneNormalizedAddress_comeBackInOneOrder() {
        let context = TestCoreDataStack().newBackgroundContext()
        context.performAndWait {
            let rows = [
                Self.makeRow(email: "ada@example.com", name: "Ada Lovelace", in: context),
                Self.makeRow(email: "Ada@Example.com", name: "Ada", in: context),
                Self.makeRow(email: "ada@example.com", name: "A. Lovelace", in: context),
                Self.makeRow(email: "alan@example.com", name: "Alan Turing", in: context)
            ]
            let expected = [
                "Ada@Example.com|Ada",
                "ada@example.com|A. Lovelace",
                "ada@example.com|Ada Lovelace",
                "alan@example.com|Alan Turing"
            ]

            for permutation in Self.permutations(of: rows) {
                let ordered = ConversationParticipantExtractor.participantsInDisplayOrder(permutation)
                XCTAssertEqual(
                    ordered.map { "\($0.person?.email ?? "")|\($0.person?.displayName ?? "")" },
                    expected
                )
            }
        }
    }

    // MARK: - A saved group, loaded again

    /// Revert-check: `extractNonMeParticipants` walking
    /// `participantsInDisplayOrder(participants)`. Walking `participants` itself
    /// gives several orders in one run of this test.
    func testExtractNonMeParticipants_savedGroupLoadedThroughFreshContexts_returnsOneOrder() throws {
        for storeKind in [TestCoreDataStack.StoreKind.inMemory, .sqlite] {
            let stack = TestCoreDataStack(storeKind: storeKind)
            let conversationID = try Self.makeSavedGroup(in: stack)

            var orders = Set<[String]>()
            for _ in 0..<Self.loadCount {
                let context = stack.newBackgroundContext()
                let order = context.performAndWait {
                    Self.extractedEmails(of: conversationID, in: context)
                }
                orders.insert(order)
            }

            XCTAssertEqual(orders, [Self.orderedEmails], "store: \(storeKind)")
        }
    }

    /// The app's view context is one long-lived context whose objects are turned
    /// back into faults as saves merge in; the set is rebuilt each time one
    /// fires.
    ///
    /// Revert-check: the same walk as the test above.
    func testExtractNonMeParticipants_oneContextRefreshedBetweenLoads_returnsOneOrder() throws {
        for storeKind in [TestCoreDataStack.StoreKind.inMemory, .sqlite] {
            let stack = TestCoreDataStack(storeKind: storeKind)
            let conversationID = try Self.makeSavedGroup(in: stack)
            let context = stack.newBackgroundContext()

            var orders = Set<[String]>()
            for _ in 0..<Self.loadCount {
                let order = context.performAndWait {
                    let order = Self.extractedEmails(of: conversationID, in: context)
                    context.refreshAllObjects()
                    return order
                }
                orders.insert(order)
            }

            XCTAssertEqual(orders, [Self.orderedEmails], "store: \(storeKind)")
        }
    }

    /// The conversation row and the chat title both show this `ParticipantInfo`.
    /// Each load gets its own loader, so the rollup cache cannot hand back the
    /// first load's order.
    ///
    /// Revert-check: `extractNonMeParticipants` walking
    /// `participantsInDisplayOrder(participants)`, which the loader's snapshot
    /// takes its emails from. With the set walked as it came, a group of eight
    /// also showed a different four people from one load to the next.
    @MainActor
    func testLoadParticipants_savedGroupLoadedThroughFreshContexts_titleAndAvatarsKeepOneOrder() async throws {
        for storeKind in [TestCoreDataStack.StoreKind.inMemory, .sqlite] {
            let stack = TestCoreDataStack(storeKind: storeKind)
            let conversationID = try Self.makeSavedGroup(in: stack)

            var titles = Set<String>()
            var avatarNames = Set<[String]>()
            var avatarEmails = Set<[String]>()
            var avatarPhotoURLs = Set<[String?]>()
            for _ in 0..<Self.loadCount {
                let info = await Self.makeLoader().loadParticipants(
                    from: conversationID,
                    in: stack.makeMainQueueViewContext(),
                    currentUserEmail: Self.myEmail,
                    maxParticipants: 4,
                    includePhotos: true
                )
                titles.insert(info.formattedDisplayName)
                avatarNames.insert(info.avatarDisplayNames)
                avatarEmails.insert(info.emails)
                avatarPhotoURLs.insert(info.avatarPhotos.map { $0?.url })
            }

            // The avatar stack shows the first four, and they are the four
            // lowest addresses.
            let firstFourEmails = Array(Self.orderedEmails.prefix(4))
            XCTAssertEqual(
                titles,
                [Self.orderedFirstNames.prefix(4).joined(separator: ", ") + " +4"],
                "store: \(storeKind)"
            )
            XCTAssertEqual(avatarNames, [Array(Self.orderedNames.prefix(4))], "store: \(storeKind)")
            XCTAssertEqual(avatarEmails, [firstFourEmails], "store: \(storeKind)")
            XCTAssertEqual(
                avatarPhotoURLs,
                [firstFourEmails.map { Optional("photo://\($0)") }],
                "store: \(storeKind)"
            )
        }
    }

    /// The stored title is rewritten by every rollup, each in a context of its
    /// own, and the row shows it until its participants load. It lists the
    /// people in the order the loaded title does (the test above), in its own
    /// format.
    ///
    /// Revert-check: `ConversationRollupUpdater.updateDisplayNameOnly` walking
    /// `ConversationParticipantExtractor.participantsInDisplayOrder(participants)`.
    func testUpdateDisplayNameOnly_savedGroupRolledUpInFreshContexts_storesOneTitle() throws {
        for storeKind in [TestCoreDataStack.StoreKind.inMemory, .sqlite] {
            let stack = TestCoreDataStack(storeKind: storeKind)
            let conversationID = try Self.makeSavedGroup(in: stack)
            let updater = ConversationRollupUpdater()

            var storedTitles = Set<String?>()
            for _ in 0..<Self.loadCount {
                let context = stack.newBackgroundContext()
                let storedTitle: String? = context.performAndWait {
                    guard let conversation = try? context.existingObject(with: conversationID) as? Conversation else {
                        XCTFail("The saved group is missing")
                        return nil
                    }
                    updater.updateDisplayNameOnly(for: conversation, myEmail: Self.myEmail)
                    let storedTitle = conversation.displayName
                    // Every rollup starts from the title the store holds.
                    context.rollback()
                    return storedTitle
                }
                storedTitles.insert(storedTitle)
            }

            let expected = Self.orderedFirstNames.dropLast().joined(separator: ", ")
                + " & " + Self.orderedFirstNames[Self.orderedFirstNames.count - 1]
            XCTAssertEqual(storedTitles, [expected], "store: \(storeKind)")
        }
    }

    // MARK: - Helpers

    /// Saves one eight-person group through a background context and returns
    /// its permanent object ID.
    private static func makeSavedGroup(in stack: TestCoreDataStack) throws -> NSManagedObjectID {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            let builder = ConversationBuilder()
                .withDisplayName("Group")
                .withParticipantHash(calculateParticipantHash(from: Self.orderedEmails))
            for entry in Self.people {
                let person = PersonBuilder()
                    .withEmail(entry.email)
                    .withDisplayName(entry.name)
                    .build(in: context)
                _ = builder.withParticipant(person)
            }
            let conversation = builder.build(in: context)
            conversation.conversationType = .group
            try context.save()
            return conversation.objectID
        }
    }

    /// Must be called on `context`'s queue.
    private static func extractedEmails(
        of conversationID: NSManagedObjectID,
        in context: NSManagedObjectContext
    ) -> [String] {
        guard let conversation = try? context.existingObject(with: conversationID) as? Conversation else {
            XCTFail("The saved group is missing")
            return []
        }
        return ConversationParticipantExtractor.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: Self.myEmail,
            currentUserAliases: [Self.myEmail]
        )
    }

    /// Must be called on `context`'s queue.
    private static func makeRow(
        email: String,
        name: String,
        in context: NSManagedObjectContext
    ) -> ConversationParticipant {
        let row = context.insertTestObject(ConversationParticipant.self)
        row.id = UUID()
        row.participantRole = .normal
        row.person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(name)
            .build(in: context)
        return row
    }

    @MainActor
    private static func makeLoader() -> ParticipantLoader {
        ParticipantLoader(
            contactsResolver: NobodyContactsResolver(),
            currentUserAliasesProvider: { _, _ in [Self.myEmail] },
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { emails in
                emails.map { ProfilePhoto(source: .cached, imageData: nil, url: "photo://\($0)") }
            },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )
    }

    private static func permutations<Element>(of elements: [Element]) -> [[Element]] {
        guard elements.count > 1 else { return [elements] }
        return elements.indices.flatMap { index -> [[Element]] in
            var rest = elements
            let first = rest.remove(at: index)
            return permutations(of: rest).map { [first] + $0 }
        }
    }
}
