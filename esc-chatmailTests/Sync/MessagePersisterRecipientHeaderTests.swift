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
