import CoreData
import XCTest
@testable import esc_chatmail

/// A display name is the sender's, and an address written inside it is not
/// the mailbox's address (architecture review gap-mime-decoding-i18n#2 and #6).
/// Each test runs the headers through `MessageProcessor` and
/// `MessagePersister.createNewMessage`, the path sync takes, and reads what
/// was stored: the message's sender fields, its participant rows and its
/// conversation.
final class MessagePersisterForgedSenderTests: XCTestCase {
    private var stack: TestCoreDataStack!

    private static let myAddress = "me@gmail.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    /// The user's own address inside a quoted From name made `isFromMe` true:
    /// the bubble was drawn as sent by the user, in note-to-self.
    ///
    /// Revert-check: reading the first `<…@…>` anywhere again in
    /// `EmailNormalizer.extractEmail` fails every assertion on the sender.
    func testCreate_fromNameQuotingTheUsersAddress_storesTheRealSenderAndIsNotFromMe() async throws {
        let stored = try await persist(headers: [
            MessageHeader(name: "From", value: #""Me <me@gmail.com>" <x@attacker.example>"#),
            MessageHeader(name: "To", value: Self.myAddress),
            MessageHeader(name: "Subject", value: "Forged")
        ])

        XCTAssertFalse(stored.isFromMe)
        XCTAssertEqual(stored.senderEmail, "x@attacker.example")
        XCTAssertEqual(stored.fromEmails, ["x@attacker.example"])
        XCTAssertEqual(stored.conversationEmails, ["x@attacker.example"])
        XCTAssertEqual(
            stored.participantHash,
            makeParticipantSetIdentity(normalizedEmails: ["x@attacker.example"], myAliases: [Self.myAddress]).participantHash
        )
    }

    /// Another person's address inside a quoted From name keyed the message
    /// into that person's chat, under that person's name.
    func testCreate_fromNameQuotingAnotherAddress_keysOnTheRealSender() async throws {
        let stored = try await persist(headers: [
            MessageHeader(name: "From", value: #""Boss <boss@corp.example>" <x@attacker.example>"#),
            MessageHeader(name: "To", value: Self.myAddress)
        ])

        XCTAssertEqual(stored.senderEmail, "x@attacker.example")
        XCTAssertEqual(stored.fromEmails, ["x@attacker.example"])
        XCTAssertEqual(stored.conversationEmails, ["x@attacker.example"])
        XCTAssertEqual(stored.senderName, "Boss <boss@corp.example>")
    }

    /// A real From address the scanner cannot read (a quoted local part),
    /// then a comma and a comment holding the user's address: one mailbox
    /// to Gmail, and the comment's address was read in its place.
    ///
    /// HONEST SCOPE: two rules each keep this from the user's address, so
    /// this fails only with both reverted: reading on to the next token after
    /// an `.unreadable` one in `EmailNormalizer.firstMailbox`, and letting
    /// step 3 of `scanMailbox` run on a header of more than one token. Each
    /// alone is pinned in `EmailNormalizerTests`.
    func testCreate_unreadableFromFollowedByCommentedUserAddress_isNotFromMe() async throws {
        let stored = try await persist(headers: [
            MessageHeader(name: "From", value: #""x"@attacker.example, (<me@gmail.com>"#),
            MessageHeader(name: "To", value: Self.myAddress)
        ])

        XCTAssertFalse(stored.isFromMe)
        XCTAssertNil(stored.senderEmail)
        XCTAssertEqual(stored.fromEmails, [])
    }

    /// A To name that decodes to `<boss@corp.example> (` replaced the
    /// recipient's address once the persister joined the decoded name to the
    /// address and parsed the result again: the open comment hides the real
    /// address, and the decoded one is the last address before it.
    ///
    /// Revert-check: joining the name and address again in
    /// `MessagePersister.saveParticipants` (`"\(name) <\(email)>"` through
    /// `saveParticipant(from:…)`) fails the To row; doing it again in
    /// `ConversationManager.createConversationIdentity` fails the conversation.
    func testCreate_encodedRecipientNameDecodingToAnAddress_keepsTheRealRecipient() async throws {
        let stored = try await persist(headers: [
            MessageHeader(name: "From", value: "Alice <alice@example.com>"),
            MessageHeader(name: "To", value: "=?utf-8?Q?=3Cboss@corp.example=3E_=28?= <bob@real.example>, me@gmail.com")
        ])

        XCTAssertEqual(stored.toEmails, ["bob@real.example", Self.myAddress])
        XCTAssertEqual(stored.conversationEmails, ["alice@example.com", "bob@real.example"])
    }

    /// A To name holding an address and a comma added a phantom participant
    /// to the conversation, and once `extractEmail` read the first mailbox of
    /// a list, the name's address would have replaced the To row's too.
    ///
    /// Revert-check: joining the name and address again in
    /// `MessagePersister.saveParticipants` fails the To row; doing it again in
    /// `ConversationManager.createConversationIdentity` fails the conversation.
    func testCreate_recipientNameWithAddressAndComma_addsNoParticipant() async throws {
        let stored = try await persist(headers: [
            MessageHeader(name: "From", value: "Alice <alice@example.com>"),
            MessageHeader(name: "To", value: #""bob@old.example, Bob" <bob@new.example>, me@gmail.com"#)
        ])

        XCTAssertEqual(stored.toEmails, ["bob@new.example", Self.myAddress])
        XCTAssertEqual(stored.conversationEmails, ["alice@example.com", "bob@new.example"])
    }

    // MARK: - Helpers

    private struct StoredMessage {
        let isFromMe: Bool
        let senderEmail: String?
        let senderName: String?
        let fromEmails: [String]
        let toEmails: [String]
        let conversationEmails: [String]
        let participantHash: String?
    }

    private func persist(headers: [MessageHeader]) async throws -> StoredMessage {
        let gmailMessage = GmailMessage(
            id: "forged-sender",
            threadId: "thread-forged-sender",
            labelIds: ["INBOX"],
            snippet: "Body",
            historyId: "1",
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/plain",
                filename: nil,
                headers: headers,
                body: MessageBody(size: 4, data: Data("Body".utf8).base64EncodedString(), attachmentId: nil),
                parts: nil
            ),
            sizeEstimate: nil
        )
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in Data() })
        let processed = try await processor.processGmailMessage(gmailMessage, myAliases: [Self.myAddress])
        let arrival = try XCTUnwrap(processed)

        let context = stack.newBackgroundContext()
        let persister = MessagePersister(photoPrefetcher: { _ in })
        try await persister.createNewMessage(
            arrival,
            labelIds: ["INBOX"],
            myAliases: [Self.myAddress],
            in: context
        )
        try await context.perform { try context.save() }

        let verificationContext = stack.newBackgroundContext()
        return try await verificationContext.perform {
            let message = try XCTUnwrap(try verificationContext.fetch(Message.fetchRequest()).first)
            func emails(_ kind: ParticipantKind) -> [String] {
                (message.participants ?? [])
                    .filter { $0.participantKind == kind }
                    .compactMap { $0.person?.email }
                    .sorted()
            }
            let conversation = message.conversation
            return StoredMessage(
                isFromMe: message.isFromMe,
                senderEmail: message.senderEmail,
                senderName: message.value(forKey: "senderName") as? String,
                fromEmails: emails(.from),
                toEmails: emails(.to),
                conversationEmails: (conversation?.participants ?? [])
                    .compactMap { $0.person?.email }
                    .sorted(),
                participantHash: conversation?.participantHash
            )
        }
    }
}
