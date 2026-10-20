import CoreData
import XCTest
@testable import esc_chatmail

final class MessagePersisterRecipientHeaderTests: XCTestCase {
    private var stack: TestCoreDataStack!

    private let rawTo = "Original Recipient <First.Last+orders@googlemail.com>"
    private let rawCc = "=?UTF-8?Q?Original_Team?= <Team.Name+copy@gmail.com>"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    func testCreatePersistsOriginalRecipientHeadersAlongsideNormalizedParticipants() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(rawToHeader: rawTo, rawCcHeader: rawCc),
            labelIds: nil,
            myAliases: ["me@example.com"],
            in: context
        )
        try await context.perform { try context.save() }

        try await assertDurableHeaders(to: rawTo, cc: rawCc)
        let verificationContext = stack.newBackgroundContext()
        try await verificationContext.perform {
            let message = try XCTUnwrap(try verificationContext.fetch(Message.fetchRequest()).first)
            let toEmails = (message.participants ?? [])
                .filter { $0.participantKind == .to }
                .compactMap { $0.person?.email }
            let ccEmails = (message.participants ?? [])
                .filter { $0.participantKind == .cc }
                .compactMap { $0.person?.email }
            XCTAssertEqual(toEmails, ["firstlast@gmail.com"])
            XCTAssertEqual(ccEmails, ["teamname@gmail.com"])
        }
    }

    func testRefetchBackfillsOriginalRecipientHeadersOnExistingMessage() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()
        try await persister.createNewMessage(
            makeArrival(rawToHeader: nil, rawCcHeader: nil),
            labelIds: nil,
            myAliases: ["me@example.com"],
            in: context
        )
        try await context.perform { try context.save() }
        try await assertDurableHeaders(to: nil, cc: nil)

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(rawToHeader: rawTo, rawCcHeader: rawCc),
            labelIds: nil,
            in: context
        )
        XCTAssertTrue(didUpdate)
        try await context.perform { try context.save() }

        try await assertDurableHeaders(to: rawTo, cc: rawCc)
    }

    func testHeaderlessUpdatePreservesStoredRecipientHeaders() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()
        try await persister.createNewMessage(
            makeArrival(rawToHeader: rawTo, rawCcHeader: rawCc),
            labelIds: nil,
            myAliases: ["me@example.com"],
            in: context
        )
        try await context.perform { try context.save() }
        var headerlessArrival = makeArrival(rawToHeader: nil, rawCcHeader: nil)
        headerlessArrival.headers = ProcessedHeaders()

        let didUpdate = await persister.updateExistingMessage(
            headerlessArrival,
            labelIds: nil,
            in: context
        )
        XCTAssertTrue(didUpdate)
        try await context.perform { try context.save() }

        try await assertDurableHeaders(to: rawTo, cc: rawCc)
    }

    func testExplicitEmptyCcHeaderReplacesStoredCcWithoutClearingTo() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()
        try await persister.createNewMessage(
            makeArrival(rawToHeader: rawTo, rawCcHeader: rawCc),
            labelIds: nil,
            myAliases: ["me@example.com"],
            in: context
        )
        try await context.perform { try context.save() }
        var arrival = makeArrival(rawToHeader: nil, rawCcHeader: "")
        arrival.headers.cc = []

        let didUpdate = await persister.updateExistingMessage(
            arrival,
            labelIds: nil,
            in: context
        )
        XCTAssertTrue(didUpdate)
        try await context.perform { try context.save() }

        try await assertDurableHeaders(to: rawTo, cc: "")
    }

    // MARK: - Recipient display names

    private let jacob = "jacob.laycock@studs.com"
    private let me = EmailAddress(email: "me@example.com", displayName: "Me")

    /// The reported ordering: his own From header names him, then a reply whose
    /// To header repeats his address as the display name
    /// (`"jacob.laycock@studs.com" <jacob.laycock@studs.com>`) is persisted.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (`PersonFactory.findOrCreate` stored the address).
    func testCreate_fromHeaderNameThenAddressShapedToName_keepsFromHeaderName() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeNamedArrival(id: "jacob-writes", from: "Jacob Laycock <\(jacob)>", to: [me], secondsAfterBase: 0),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }
        try await assertStoredDisplayName("Jacob Laycock", forEmail: jacob)

        try await persister.createNewMessage(
            makeNamedArrival(
                id: "reply-to-jacob",
                from: "Me <\(me.email)>",
                to: [EmailAddress(email: jacob, displayName: jacob)],
                isFromMe: true,
                secondsAfterBase: 60
            ),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }

        try await assertStoredDisplayName("Jacob Laycock", forEmail: jacob)
    }

    /// Same ordering through the refetch path: the reply first arrives with a
    /// bare address, and a later full fetch supplies the address-shaped name.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (`MessagePersister.updateKnownParticipantDisplayNames` stored the address).
    func testRefetch_addressShapedToNameDoesNotReplaceFromHeaderName() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeNamedArrival(id: "jacob-writes", from: "Jacob Laycock <\(jacob)>", to: [me], secondsAfterBase: 0),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await persister.createNewMessage(
            makeNamedArrival(
                id: "reply-to-jacob",
                from: "Me <\(me.email)>",
                to: [EmailAddress(email: jacob, displayName: nil)],
                isFromMe: true,
                secondsAfterBase: 60
            ),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }
        try await assertStoredDisplayName("Jacob Laycock", forEmail: jacob)

        _ = await persister.updateExistingMessage(
            makeNamedArrival(
                id: "reply-to-jacob",
                from: "Me <\(me.email)>",
                to: [EmailAddress(email: jacob, displayName: jacob)],
                isFromMe: true,
                secondsAfterBase: 60
            ),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }

        try await assertStoredDisplayName("Jacob Laycock", forEmail: jacob)
    }

    /// A row that already holds the address (no header has named him yet) takes
    /// the name the next From header gives, even a one-word name shorter than
    /// the address. This is how rows corrupted before the fix heal.
    ///
    /// Revert-check: removing the `isEmailAddressShapedDisplayName` guard in
    /// `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails this test
    /// (the address kept the row).
    func testCreate_addressShapedToNameThenOneWordFromName_storesFromHeaderName() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeNamedArrival(
                id: "write-to-jacob",
                from: "Me <\(me.email)>",
                to: [EmailAddress(email: jacob, displayName: jacob)],
                isFromMe: true,
                secondsAfterBase: 0
            ),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }
        try await assertStoredDisplayName(jacob, forEmail: jacob)

        try await persister.createNewMessage(
            makeNamedArrival(id: "jake-replies", from: "Jake <\(jacob)>", to: [me], secondsAfterBase: 60),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }

        try await assertStoredDisplayName("Jake", forEmail: jacob)
    }

    /// The same ordering for an internationalized address: header extraction
    /// takes it from the angle brackets, but the bare-address pattern does not
    /// match it as a display name.
    ///
    /// Revert-check: removing the `normalize(displayName) == normalize(email)`
    /// term in `EmailNormalizer.isEmailAddressShapedDisplayName(_:forEmail:)`
    /// fails this test (`PersonFactory.findOrCreate` stored the address).
    func testCreate_fromHeaderNameThenRepeatedInternationalizedAddress_keepsFromHeaderName() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()
        let jose = "jose@correo.españa"

        try await persister.createNewMessage(
            makeNamedArrival(id: "jose-writes", from: "José <\(jose)>", to: [me], secondsAfterBase: 0),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await persister.createNewMessage(
            makeNamedArrival(
                id: "reply-to-jose",
                from: "Me <\(me.email)>",
                to: [EmailAddress(email: jose, displayName: jose)],
                isFromMe: true,
                secondsAfterBase: 60
            ),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }

        try await assertStoredDisplayName("José", forEmail: jose)
    }

    /// His From header names him "Jake Laycock", then a reply's To header names
    /// him "Jacob Laycock", which matches his address and ties on part count.
    ///
    /// Revert-check: removing the part-count `guard` from the derived-candidate
    /// branch of `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)` fails
    /// this test (`PersonFactory.findOrCreate` stored the longer "Jacob Laycock").
    func testCreate_fromHeaderNameThenAddressDerivedToName_keepsFromHeaderName() async throws {
        let context = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeNamedArrival(id: "jake-writes", from: "Jake Laycock <\(jacob)>", to: [me], secondsAfterBase: 0),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }
        try await assertStoredDisplayName("Jake Laycock", forEmail: jacob)

        try await persister.createNewMessage(
            makeNamedArrival(
                id: "reply-to-jake",
                from: "Me <\(me.email)>",
                to: [EmailAddress(email: jacob, displayName: "Jacob Laycock")],
                isFromMe: true,
                secondsAfterBase: 60
            ),
            labelIds: nil,
            myAliases: [me.email],
            in: context
        )
        try await context.perform { try context.save() }

        try await assertStoredDisplayName("Jake Laycock", forEmail: jacob)
    }

    private func makeNamedArrival(
        id: String,
        from: String,
        to: [EmailAddress],
        isFromMe: Bool = false,
        secondsAfterBase: TimeInterval
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Studs"
        headers.from = from
        headers.to = to
        headers.isFromMe = isFromMe

        var arrival = ProcessedMessage()
        arrival.id = id
        arrival.gmThreadId = "thread-studs"
        arrival.internalDate = Date(timeIntervalSince1970: 1_700_000_000 + secondsAfterBase)
        arrival.headers = headers
        arrival.snippet = "Body"
        arrival.plainTextBody = "Body"
        return arrival
    }

    /// Duplicate-email Person rows are legal, so every row for the address must
    /// carry the name, not just whichever one a fetch returns first.
    private func assertStoredDisplayName(
        _ expected: String,
        forEmail email: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let context = stack.newBackgroundContext()
        try await context.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            let names = try context.fetch(request).map(\.displayName)
            XCTAssertFalse(names.isEmpty, "No Person row for the address", file: file, line: line)
            XCTAssertEqual(names, [String?](repeating: expected, count: names.count), file: file, line: line)
        }
    }

    private func makePersister() -> MessagePersister {
        MessagePersister(photoPrefetcher: { _ in })
    }

    private func makeArrival(rawToHeader: String?, rawCcHeader: String?) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Recipient fidelity"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "firstlast@gmail.com", displayName: "Original Recipient")]
        headers.cc = [EmailAddress(email: "teamname@gmail.com", displayName: "Original Team")]
        headers.rawToHeader = rawToHeader
        headers.rawCcHeader = rawCcHeader

        var arrival = ProcessedMessage()
        arrival.id = "message-recipient-headers"
        arrival.gmThreadId = "thread-recipient-headers"
        arrival.internalDate = Date(timeIntervalSince1970: 1_700_000_000)
        arrival.headers = headers
        arrival.snippet = "Original body"
        arrival.plainTextBody = "Original body"
        return arrival
    }

    private func assertDurableHeaders(
        to expectedTo: String?,
        cc expectedCc: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let context = stack.newBackgroundContext()
        try await context.perform {
            let message = try XCTUnwrap(try context.fetch(Message.fetchRequest()).first)
            XCTAssertEqual(message.rawToHeader, expectedTo, file: file, line: line)
            XCTAssertEqual(message.rawCcHeader, expectedCc, file: file, line: line)
        }
    }
}
