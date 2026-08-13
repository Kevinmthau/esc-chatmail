import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class GmailSendServiceTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var apiClient: MockGmailAPIClient!
    private var authSession: AuthSession!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        apiClient = MockGmailAPIClient()
        authSession = AuthSession()
        authSession.userEmail = "sender@example.com"
        authSession.userName = "Sender"
        sendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: apiClient,
            authSession: authSession
        )
    }

    override func tearDown() {
        sendService = nil
        authSession = nil
        apiClient = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testSendNew_usesInjectedGmailAPIClient() async throws {
        apiClient.sendMessageResponse = SendMessageResponse(id: "sent-id", threadId: "thread-id")

        let result = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject"
        )

        XCTAssertEqual(result.messageId, "sent-id")
        XCTAssertEqual(result.threadId, "thread-id")
        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCalls.first?.threadId, nil)
        XCTAssertFalse(apiClient.sendMessageCalls.first?.rawMessage.isEmpty ?? true)
    }

    func testSendNew_carriesProvidedReconciliationMessageIDInMIME() async throws {
        let messageID = MimeBuilder.messageId(
            forOptimisticMessageID: "optimistic-message-id"
        )

        _ = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject",
            messageId: messageID
        )

        let rawMessage = try XCTUnwrap(
            apiClient.sendMessageCalls.first?.rawMessage
        )
        let mimeData = try XCTUnwrap(Data(base64UrlEncoded: rawMessage))
        let mime = try XCTUnwrap(String(data: mimeData, encoding: .utf8))
        XCTAssertTrue(mime.contains("Message-ID: \(messageID)\r\n"))
    }

    func testSendNew_messageIDHeaderInjection_isCollapsedIntoSingleHeader() async throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildSimpleMessage. Without that call the raw CRLF reaches the MIME and
        // the injected "Bcc:" becomes a real header line.
        _ = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject",
            messageId: injectedMessageID
        )

        let mime = try decodedMIMEFromFirstSendCall()
        XCTAssertEqual(headerLines(in: mime, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: mime, named: "Message-ID"), [collapsedInjectedMessageIDHeader])
    }

    func testSendNew_deterministicReconciliationMessageID_survivesSanitizationByteIdentically() async throws {
        // HONEST SCOPE: this test PASSES with the sanitizeHeaderValue call deleted — it
        // pins the no-op direction only, failing if the sanitizer is ever STRENGTHENED
        // to rewrite a deterministic ID. Sync matches an outbound echo by re-deriving
        // this exact string, so even a one-byte rewrite silently breaks send
        // convergence. Deletion of the call is caught by the injection tests instead.
        let messageID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")

        _ = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject",
            messageId: messageID
        )

        let mime = try decodedMIMEFromFirstSendCall()
        let emitted = try emittedMessageIDValue(in: mime)
        XCTAssertEqual(emitted, messageID)
        XCTAssertEqual(MimeBuilder.optimisticMessageID(from: emitted), "optimistic-id")
    }

    func testBuildSimpleMessage_messageID_blocksInjectionAndPreservesDeterministicID() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildSimpleMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                messageId: injectedMessageID
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: injected, named: "Message-ID"), [collapsedInjectedMessageIDHeader])

        let deterministicID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")
        let preserved = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                messageId: deterministicID
            )
        )
        XCTAssertEqual(try emittedMessageIDValue(in: preserved), deterministicID)
    }

    func testBuildAlternativeMessage_messageID_blocksInjectionAndPreservesDeterministicID() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildAlternativeMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: [],
                messageId: injectedMessageID
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: injected, named: "Message-ID"), [collapsedInjectedMessageIDHeader])

        let deterministicID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")
        let preserved = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: [],
                messageId: deterministicID
            )
        )
        XCTAssertEqual(try emittedMessageIDValue(in: preserved), deterministicID)
    }

    func testBuildMultipartMessage_messageID_blocksInjectionAndPreservesDeterministicID() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildMultipartMessage.
        let attachment = AttachmentData(
            data: Data("attachment".utf8),
            filename: "note.txt",
            mimeType: "text/plain"
        )
        let injected = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [attachment],
                messageId: injectedMessageID
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: injected, named: "Message-ID"), [collapsedInjectedMessageIDHeader])

        let deterministicID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")
        let preserved = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [attachment],
                messageId: deterministicID
            )
        )
        XCTAssertEqual(try emittedMessageIDValue(in: preserved), deterministicID)
    }

    func testSendNew_toRecipientHeaderInjection_isCollapsedIntoSingleHeader() async throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied per-recipient to the To:
        // header in MimeBuilder.buildSimpleMessage. Without that call the raw CRLF in a
        // recipient reaches the MIME and the injected "Bcc:" becomes a real header line.
        _ = try await sendService.sendNew(
            to: [injectedRecipient],
            body: "Hello world",
            subject: "Subject"
        )

        let mime = try decodedMIMEFromFirstSendCall()
        XCTAssertEqual(headerLines(in: mime, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: mime, named: "To"), [collapsedInjectedToHeader])
    }

    func testBuildSimpleMessage_toRecipients_blockInjectionAndPreserveCleanRecipients() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied per-recipient to the To:
        // header in MimeBuilder.buildSimpleMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: [injectedRecipient, "second@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: []
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(
            headerLines(in: injected, named: "To"),
            ["\(collapsedInjectedToHeader), second@example.com"]
        )

        let clean = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["a@example.com", "b@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: []
            )
        )
        XCTAssertEqual(headerLines(in: clean, named: "To"), ["To: a@example.com, b@example.com"])
    }

    func testBuildAlternativeMessage_toRecipients_blockInjectionAndPreserveCleanRecipients() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied per-recipient to the To:
        // header in MimeBuilder.buildAlternativeMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: [injectedRecipient, "second@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: []
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(
            headerLines(in: injected, named: "To"),
            ["\(collapsedInjectedToHeader), second@example.com"]
        )

        let clean = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["a@example.com", "b@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: []
            )
        )
        XCTAssertEqual(headerLines(in: clean, named: "To"), ["To: a@example.com, b@example.com"])
    }

    func testBuildMultipartMessage_toRecipients_blockInjectionAndPreserveCleanRecipients() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied per-recipient to the To:
        // header in MimeBuilder.buildMultipartMessage.
        let attachment = AttachmentData(
            data: Data("attachment".utf8),
            filename: "note.txt",
            mimeType: "text/plain"
        )
        let injected = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: [injectedRecipient, "second@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [attachment]
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(
            headerLines(in: injected, named: "To"),
            ["\(collapsedInjectedToHeader), second@example.com"]
        )

        let clean = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["a@example.com", "b@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [attachment]
            )
        )
        XCTAssertEqual(headerLines(in: clean, named: "To"), ["To: a@example.com, b@example.com"])
    }

    func testBuildSimpleMessage_fromEmailHeaderInjection_isCollapsedIntoSingleHeader() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the email in
        // MimeBuilder.formatFromHeader (every builder interpolates its return value
        // raw into the From: header).
        let injected = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["to@example.com"],
                from: injectedFromEmail,
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: []
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(
            headerLines(in: injected, named: "From"),
            ["From: \(collapsedInjectedFromEmail)"]
        )
    }

    func testFormatFromHeader_emailInjection_isCollapsedOnEveryReturnPath() {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the email in
        // MimeBuilder.formatFromHeader. The email is interpolated on all three return
        // paths (bare email, encoded name, quoted name), so each must collapse CRLF.
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: injectedFromEmail, name: nil),
            collapsedInjectedFromEmail
        )
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: injectedFromEmail, name: "Plain Name"),
            "Plain Name <\(collapsedInjectedFromEmail)>"
        )
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: injectedFromEmail, name: "Quoted, Name"),
            "\"Quoted, Name\" <\(collapsedInjectedFromEmail)>"
        )
    }

    func testFormatFromHeader_quotedNameWithQuoteAndCRLF_isCollapsedInsideQuotes() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the quoted-name path in
        // MimeBuilder.formatFromHeader. Quote-escaping alone leaves the CRLF intact, so a
        // display name carrying a quote AND a CRLF used to inject a header.
        let result = MimeBuilder.formatFromHeader(
            email: "sender@example.com",
            name: "Evil \"Name\r\nBcc: attacker@example.com"
        )
        XCTAssertEqual(
            result,
            "\"Evil \\\"Name Bcc: attacker@example.com\" <sender@example.com>"
        )

        let injected = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: "Evil \"Name\r\nBcc: attacker@example.com",
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: []
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(
            headerLines(in: injected, named: "From"),
            ["From: \"Evil \\\"Name Bcc: attacker@example.com\" <sender@example.com>"]
        )
    }

    func testFormatFromHeader_quotedNameWithBackslash_escapesQuotedPair() {
        // Revert-check: the backslash escape on the quoted-name path in
        // MimeBuilder.formatFromHeader. Without it a display name ending in a bare
        // backslash turns the closing quote into an RFC 5322 quoted-pair, leaving the
        // quoted-string unterminated so the address is swallowed and the From: header
        // is unparseable (Gmail rejects the send with a 400).
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: "sender@example.com", name: "Thau, Kevin\\"),
            "\"Thau, Kevin\\\\\" <sender@example.com>"
        )

        // Backslash-before-quote must escape the backslash first, then the quote, so
        // both survive as separate quoted-pairs.
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: "sender@example.com", name: "A\\\"B"),
            "\"A\\\\\\\"B\" <sender@example.com>"
        )
    }

    func testFormatFromHeader_cleanIdentity_isPreservedByteIdentically() {
        // HONEST SCOPE: this test PASSES with the sanitizeHeaderValue calls deleted — it
        // pins the no-op direction only, failing if the sanitizer is ever STRENGTHENED to
        // rewrite a clean identity. The optimistic sender-name round trip
        // (GmailSendService+OptimisticUpdates) stores
        // extractDisplayName(formatFromHeader(...)) and must stay byte-equal to what the
        // echo's persister parses back; a rewrite here would silently fork the two.
        // Deletion of the calls is caught by the injection tests instead.
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: "sender@example.com", name: nil),
            "sender@example.com"
        )
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: "sender@example.com", name: "Sender"),
            "Sender <sender@example.com>"
        )
        XCTAssertEqual(
            MimeBuilder.formatFromHeader(email: "sender@example.com", name: "Kevin \"KT\" Thau"),
            "\"Kevin \\\"KT\\\" Thau\" <sender@example.com>"
        )
    }

    func testBuildAlternativeMessage_inlineAttachmentFilenameQuoteBreakout_isEscapedInsideQuotedParameters() throws {
        // Revert-check: MimeBuilder.quoteParameterValue applied to the inline-attachment
        // filename in MimeBuilder.buildAlternativeMessage (the multipart/related loop).
        // With only sanitizeHeaderValue there, a double-quote in the filename terminates
        // the name="…"/filename="…" quoted-string and smuggles extra MIME parameters
        // into the part header.
        let injected = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: [
                    InlineAttachmentData(
                        data: Data("image".utf8),
                        contentId: "cid-1",
                        filename: injectedAttachmentFilename,
                        mimeType: "image/png"
                    )
                ]
            )
        )
        XCTAssertEqual(
            attachmentNameHeaderLines(in: injected),
            ["Content-Type: image/png; name=\"\(escapedInjectedAttachmentFilename)\""]
        )
        XCTAssertEqual(
            headerLines(in: injected, named: "Content-Disposition"),
            ["Content-Disposition: inline; filename=\"\(escapedInjectedAttachmentFilename)\""]
        )

        let clean = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: [
                    InlineAttachmentData(
                        data: Data("image".utf8),
                        contentId: "cid-1",
                        filename: "photo.png",
                        mimeType: "image/png"
                    )
                ]
            )
        )
        XCTAssertEqual(
            attachmentNameHeaderLines(in: clean),
            ["Content-Type: image/png; name=\"photo.png\""]
        )
        XCTAssertEqual(
            headerLines(in: clean, named: "Content-Disposition"),
            ["Content-Disposition: inline; filename=\"photo.png\""]
        )
    }

    func testBuildAlternativeMessage_regularAttachmentFilenameQuoteBreakout_isEscapedInsideQuotedParameters() throws {
        // Revert-check: MimeBuilder.quoteParameterValue applied to the regular-attachment
        // filename in MimeBuilder.buildAlternativeMessage (the multipart/mixed loop).
        let injected = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [
                    AttachmentData(
                        data: Data("attachment".utf8),
                        filename: injectedAttachmentFilename,
                        mimeType: "application/pdf"
                    )
                ],
                inlineAttachments: []
            )
        )
        XCTAssertEqual(
            attachmentNameHeaderLines(in: injected),
            ["Content-Type: application/pdf; name=\"\(escapedInjectedAttachmentFilename)\""]
        )
        XCTAssertEqual(
            headerLines(in: injected, named: "Content-Disposition"),
            ["Content-Disposition: attachment; filename=\"\(escapedInjectedAttachmentFilename)\""]
        )

        let clean = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [
                    AttachmentData(
                        data: Data("attachment".utf8),
                        filename: "report.pdf",
                        mimeType: "application/pdf"
                    )
                ],
                inlineAttachments: []
            )
        )
        XCTAssertEqual(
            attachmentNameHeaderLines(in: clean),
            ["Content-Type: application/pdf; name=\"report.pdf\""]
        )
        XCTAssertEqual(
            headerLines(in: clean, named: "Content-Disposition"),
            ["Content-Disposition: attachment; filename=\"report.pdf\""]
        )
    }

    func testBuildMultipartMessage_attachmentFilenameQuoteBreakout_isEscapedInsideQuotedParameters() throws {
        // Revert-check: MimeBuilder.quoteParameterValue applied to the attachment
        // filename in MimeBuilder.buildMultipartMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [
                    AttachmentData(
                        data: Data("attachment".utf8),
                        filename: injectedAttachmentFilename,
                        mimeType: "application/pdf"
                    )
                ]
            )
        )
        XCTAssertEqual(
            attachmentNameHeaderLines(in: injected),
            ["Content-Type: application/pdf; name=\"\(escapedInjectedAttachmentFilename)\""]
        )
        XCTAssertEqual(
            headerLines(in: injected, named: "Content-Disposition"),
            ["Content-Disposition: attachment; filename=\"\(escapedInjectedAttachmentFilename)\""]
        )

        let clean = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [
                    AttachmentData(
                        data: Data("attachment".utf8),
                        filename: "report.pdf",
                        mimeType: "application/pdf"
                    )
                ]
            )
        )
        XCTAssertEqual(
            attachmentNameHeaderLines(in: clean),
            ["Content-Type: application/pdf; name=\"report.pdf\""]
        )
        XCTAssertEqual(
            headerLines(in: clean, named: "Content-Disposition"),
            ["Content-Disposition: attachment; filename=\"report.pdf\""]
        )
    }

    func testQuoteParameterValue_escapesBackslashesBeforeQuotesAndCollapsesCRLF() {
        // Revert-check: the backslash-then-quote escape order in
        // MimeBuilder.quoteParameterValue. Escaping quotes first would double-escape
        // the backslashes it adds; skipping the backslash escape lets a trailing bare
        // backslash turn the closing quote into an RFC 5322 quoted-pair, leaving the
        // quoted parameter unterminated.
        XCTAssertEqual(MimeBuilder.quoteParameterValue("report.pdf"), "report.pdf")
        XCTAssertEqual(
            MimeBuilder.quoteParameterValue(injectedAttachmentFilename),
            escapedInjectedAttachmentFilename
        )
        XCTAssertEqual(MimeBuilder.quoteParameterValue("dir\\"), "dir\\\\")
        XCTAssertEqual(MimeBuilder.quoteParameterValue("a\\\"b"), "a\\\\\\\"b")
        XCTAssertEqual(
            MimeBuilder.quoteParameterValue("evil.png\"\r\nBcc: attacker@example.com"),
            "evil.png\\\" Bcc: attacker@example.com"
        )
    }

    func testSendReply_passesThreadIdToInjectedGmailAPIClient() async throws {
        _ = try await sendService.sendReply(
            to: ["to@example.com"],
            body: "Reply body",
            subject: "Re: Subject",
            threadId: "reply-thread-id",
            inReplyTo: "<id-1>",
            references: ["<id-1>"]
        )

        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCalls.first?.threadId, "reply-thread-id")
    }

    func testSendReply_invokesTransmissionBarrierBeforeAPIRequest() async throws {
        let probe = TransmissionBarrierProbe()

        _ = try await sendService.sendReply(
            to: ["to@example.com"],
            body: "Reply body",
            subject: "Re: Subject",
            threadId: "reply-thread-id",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            beforeTransmission: {
                await probe.record()
            }
        )

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
    }

    func testSendNew_attachmentPreflightFailureDoesNotCrossTransmissionBarrier() async {
        let probe = TransmissionBarrierProbe()

        do {
            _ = try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                attachmentInfos: [
                    .init(
                        localURL: nil,
                        filename: "missing.pdf",
                        mimeType: "application/pdf"
                    )
                ],
                beforeTransmission: {
                    await probe.record()
                }
            )
            XCTFail("Expected attachment preflight failure")
        } catch {
            // Expected definite local failure.
        }

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 0)
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testSendNew_preflightCancellationDoesNotCrossTransmissionBarrier() async {
        let probe = TransmissionBarrierProbe()
        let task = Task {
            try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                beforeTransmission: {
                    await probe.record()
                }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected before request admission.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 0)
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testSendNew_transmissionBarrierFailurePreventsAPIRequest() async {
        let probe = TransmissionBarrierProbe()

        do {
            _ = try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                beforeTransmission: {
                    await probe.record()
                    throw TransmissionBarrierTestError.persistenceFailed
                }
            )
            XCTFail("Expected barrier persistence failure")
        } catch TransmissionBarrierTestError.persistenceFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testSendNew_mapsAuthenticationErrorsFromAPIClient() async {
        apiClient.sendMessageError = APIError.authenticationError

        do {
            _ = try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                subject: "Subject"
            )
            XCTFail("Expected authentication failure")
        } catch let error as GmailSendService.SendError {
            if case .authenticationFailed = error {
                return
            }
            XCTFail("Expected authenticationFailed but got \(error)")
        } catch {
            XCTFail("Expected GmailSendService.SendError.authenticationFailed but got \(error)")
        }
    }

    func testAttachmentSnapshot_doesNotMutateAttachmentState() {
        let attachment = coreDataStack.viewContext.insertTestObject(Attachment.self)
        attachment.id = "inline-1"
        attachment.filename = "inline.png"
        attachment.mimeType = "image/png"
        attachment.stateRaw = Attachment.State.downloaded.rawValue
        attachment.contentId = "cid-inline"

        let info = sendService.attachmentSnapshot(attachment)

        XCTAssertEqual(attachment.state, .downloaded)
        XCTAssertEqual(info.filename, "inline.png")
        XCTAssertEqual(info.mimeType, "image/png")
        XCTAssertEqual(info.contentId, "cid-inline")
    }

    // MARK: - MIME Helpers

    private func decodedMIMEFromFirstSendCall() throws -> String {
        let rawMessage = try XCTUnwrap(apiClient.sendMessageCalls.first?.rawMessage)
        let mimeData = try XCTUnwrap(Data(base64UrlEncoded: rawMessage))
        return try decodedMIME(mimeData)
    }

    private func decodedMIME(_ mimeData: Data) throws -> String {
        try XCTUnwrap(String(data: mimeData, encoding: .utf8))
    }

    /// Header lines are matched on the raw CRLF-delimited line boundaries, so an injected
    /// value that survives only *inside* another header's value is not counted as a header.
    /// NOTE: splits on CRLF only, so against a sanitizer weakened to bare-LF the Bcc
    /// emptiness assertion would still pass — the Message-ID EQUALITY assertion is the
    /// load-bearing one in every injection test (an uncollapsed value cannot equal the
    /// collapsed expectation).
    private func headerLines(in mime: String, named name: String) -> [String] {
        mime
            .components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("\(name):") }
    }

    /// The Content-Type lines carrying a `name=` parameter — i.e. the attachment part
    /// headers. The multipart containers (`boundary=`) and text parts (`charset=`)
    /// never carry `name=`, so this isolates the lines the filename is quoted into.
    private func attachmentNameHeaderLines(in mime: String) -> [String] {
        headerLines(in: mime, named: "Content-Type").filter { $0.contains("name=") }
    }

    private func emittedMessageIDValue(in mime: String) throws -> String {
        let lines = headerLines(in: mime, named: "Message-ID")
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        return String(line.dropFirst("Message-ID: ".count))
    }
}

private let injectedMessageID = "<a@b>\r\nBcc: attacker@example.com"
private let collapsedInjectedMessageIDHeader = "Message-ID: <a@b> Bcc: attacker@example.com"

private let injectedRecipient = "victim@example.com\r\nBcc: attacker@example.com"
private let collapsedInjectedToHeader = "To: victim@example.com Bcc: attacker@example.com"

private let injectedFromEmail = "sender@example.com\r\nBcc: attacker@example.com"
private let collapsedInjectedFromEmail = "sender@example.com Bcc: attacker@example.com"

/// Terminates the `name="…"` / `filename="…"` quoted-string and smuggles a second
/// MIME parameter if the double-quote is not escaped.
private let injectedAttachmentFilename = "evil.pdf\"; malicious=\"1"
private let escapedInjectedAttachmentFilename = "evil.pdf\\\"; malicious=\\\"1"

private enum TransmissionBarrierTestError: Error {
    case persistenceFailed
}

private actor TransmissionBarrierProbe {
    private var calls = 0

    func record() {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}
