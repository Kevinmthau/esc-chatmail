import XCTest
import CoreData
@testable import esc_chatmail

final class MessagePersisterUpdateTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var persister: MessagePersister!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        persister = MessagePersister(photoPrefetcher: { _ in })
    }

    override func tearDown() {
        persister = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testUpdateExistingMessage_updatesNewsletterClassification() async {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-newsletter-update")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.isNewsletter = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Updated snippet",
            cleanedSnippet: "Updated snippet",
            internalDate: existingMessage.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertTrue(existingMessage.isNewsletter)
    }

    func testCreateNewMessage_persistsChatPreviewText() async throws {
        var headers = ProcessedHeaders()
        headers.subject = "Chat preview"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "message-chat-preview-create",
            gmThreadId: "thread-chat-preview-create",
            snippet: "Line one. Line two.",
            cleanedSnippet: "Line one. Line two.",
            chatPreviewText: "Line one.\n\nLine two.",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Line one.\n\nLine two.",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let saved = try XCTUnwrap(fetchMessage(id: processedMessage.id))
        XCTAssertEqual(saved.chatPreviewText, "Line one.\n\nLine two.")
        XCTAssertEqual(saved.cleanedSnippet, "Line one. Line two.")
    }

    func testCreateNewMessage_schedulesInlineCIDPrefetch() async throws {
        let scheduleRecorder = InlineCIDPrefetchScheduleRecorder()
        let htmlPersister = MessagePersister(
            photoPrefetcher: { _ in },
            inlineCIDPrefetchScheduler: { request, _ in
                scheduleRecorder.record(request)
            }
        )

        var headers = ProcessedHeaders()
        headers.subject = "Inline CID"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "message-inline-cid-prefetch-create",
            gmThreadId: "thread-inline-cid-prefetch-create",
            snippet: "Inline CID",
            cleanedSnippet: "Inline CID",
            chatPreviewText: "Inline CID",
            internalDate: Date(),
            headers: headers,
            htmlBody: #"<html><body><img src="cid:Logo@Example.COM"></body></html>"#,
            plainTextBody: "Inline CID",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: "att-logo",
                    filename: "logo.png",
                    mimeType: "image/png",
                    size: 512,
                    contentId: "Logo@Example.COM"
                )
            ],
            inlineCIDPrefetchContentIDs: ["logo@example.com"],
            inlineCIDPrefetchAttachmentIDs: ["att-logo"]
        )

        try await htmlPersister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        XCTAssertEqual(scheduleRecorder.requests.count, 1)
        XCTAssertEqual(scheduleRecorder.requests.first?.messageId, processedMessage.id)
        XCTAssertEqual(scheduleRecorder.requests.first?.normalizedContentIDs, ["logo@example.com"])
        XCTAssertEqual(scheduleRecorder.requests.first?.attachmentIDs, ["att-logo"])
    }

    func testUpdateExistingMessage_updatesChatPreviewText() async throws {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-chat-preview-update")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.chatPreviewText = "Old preview"

        var headers = ProcessedHeaders()
        headers.subject = existingMessage.subject
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Updated preview.",
            cleanedSnippet: "Updated preview.",
            chatPreviewText: "Updated preview.\n\nSecond line.",
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Updated preview.\n\nSecond line.",
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.chatPreviewText, "Updated preview.\n\nSecond line.")
        XCTAssertEqual(existingMessage.cleanedSnippet, "Updated preview.")
    }

    func testUpdateExistingMessage_preservesStoredPreviewFieldsWhenIncomingPreviewIsBlank() async throws {
        let messageDate = Date(timeIntervalSince1970: 1_700_010_000)
        let conversation = ConversationBuilder()
            .withSnippet("Existing row preview")
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-blank-preview-update")
            .withSubject("Stored subject")
            .withSnippet("Stored raw preview")
            .withDate(messageDate)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.cleanedSnippet = "Stored clean preview"
        existingMessage.chatPreviewText = "Stored chat preview"

        var headers = ProcessedHeaders()
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: " \n\t ",
            cleanedSnippet: nil,
            chatPreviewText: " \n\t ",
            internalDate: messageDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: nil,
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.subject, "Stored subject")
        XCTAssertEqual(existingMessage.snippet, "Stored raw preview")
        XCTAssertEqual(existingMessage.cleanedSnippet, "Stored clean preview")
        XCTAssertEqual(existingMessage.chatPreviewText, "Stored chat preview")
        XCTAssertEqual(conversation.snippet, "Stored clean preview")
    }

    func testUpdateExistingMessage_clearsStaleHigherPriorityPreviewsWhenIncomingFallbackExists() async throws {
        let messageDate = Date(timeIntervalSince1970: 1_700_010_000)
        let conversation = ConversationBuilder()
            .withSnippet("Old row preview")
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-stale-preview-update")
            .withSubject("Stored subject")
            .withSnippet("Old raw preview")
            .withDate(messageDate)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.cleanedSnippet = "Old clean preview"
        existingMessage.chatPreviewText = "Old chat preview"

        var headers = ProcessedHeaders()
        headers.subject = existingMessage.subject
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Fresh raw preview",
            cleanedSnippet: nil,
            chatPreviewText: nil,
            internalDate: messageDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: nil,
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.snippet, "Fresh raw preview")
        XCTAssertNil(existingMessage.cleanedSnippet)
        XCTAssertNil(existingMessage.chatPreviewText)
        XCTAssertEqual(conversation.snippet, "Fresh raw preview")
    }

    func testUpdateExistingMessage_invalidatesCachesWhenStoredHTMLChangesWithSameURIAndText() async throws {
        let contentHandler = HTMLContentHandler.shared
        let messageId = "message-html-source-update-\(UUID().uuidString)"
        let oldHTML = "<!DOCTYPE html><html><body><p>OLD_HTML_TOKEN</p></body></html>"
        let newHTML = "<!DOCTYPE html><html><body><p>NEW_HTML_TOKEN</p></body></html>"
        let plainText = "Stable plain text"
        let chatPreviewText = "Preferred chat preview"
        let snippet = "Stable snippet"
        let subject = "Stable subject"
        let senderEmail = "sender@example.com"

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        await RenderedMessageCache.shared.invalidate(messageId: messageId)
        await ParsedEmailProvider.shared.invalidate(messageId: messageId)
        defer {
            contentHandler.deleteHTML(for: messageId)
        }

        let oldURL = try XCTUnwrap(contentHandler.saveHTML(oldHTML, for: messageId))
        let oldSignature = try XCTUnwrap(
            contentHandler.canonicalHTMLSourceSignature(messageId: messageId, bodyStorageURI: oldURL.absoluteString)
        )
        let newSignature = try XCTUnwrap(contentHandler.canonicalHTMLSourceSignature(for: newHTML))

        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId(messageId)
            .withSubject(subject)
            .withSender(email: senderEmail, name: "Sender")
            .withSnippet(snippet)
            .withBody(plainText)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.bodyStorageURI = oldURL.absoluteString
        existingMessage.chatPreviewText = chatPreviewText

        _ = await RenderedMessageCache.shared.wrappedOriginalHTML(
            messageId: messageId,
            sourceSignature: oldSignature,
            variantKey: "original-test"
        ) {
            "wrapped old html"
        }
        _ = await ParsedEmailProvider.shared.parsedEmail(
            messageId: messageId,
            sourceSignature: oldSignature,
            canonicalHTML: oldHTML
        )
        let oldArtifactsBeforeUpdate = await RenderedMessageCache.shared.artifacts(
            messageId: messageId,
            sourceSignature: oldSignature
        )
        let parsedSignaturesBeforeUpdate = await ParsedEmailProvider.shared.debugCachedSourceSignatures(messageId: messageId)
        XCTAssertNotNil(oldArtifactsBeforeUpdate)
        XCTAssertTrue(parsedSignaturesBeforeUpdate.contains(oldSignature))

        let sourceChangeExpectation = expectation(description: "HTML source change notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: HTMLContentLoader.contentSourceDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String == messageId else {
                return
            }
            XCTAssertEqual(
                notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey] as? String,
                newSignature
            )
            XCTAssertTrue(Thread.isMainThread)
            sourceChangeExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        var headers = ProcessedHeaders()
        headers.subject = subject
        headers.from = "Sender <\(senderEmail)>"
        headers.isFromMe = false
        let processedMessage = ProcessedMessage(
            id: messageId,
            gmThreadId: existingMessage.gmThreadId,
            snippet: snippet,
            cleanedSnippet: snippet,
            chatPreviewText: chatPreviewText,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: newHTML,
            plainTextBody: plainText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: false,
            attachmentInfo: []
        )

        let htmlPersister = MessagePersister(
            htmlContentHandler: contentHandler,
            photoPrefetcher: { _ in }
        )
        let didUpdate = await htmlPersister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.bodyStorageURI, oldURL.absoluteString)
        XCTAssertEqual(existingMessage.bodyText, plainText)
        XCTAssertEqual(existingMessage.chatPreviewText, chatPreviewText)
        let oldArtifactsAfterUpdate = await RenderedMessageCache.shared.artifacts(
            messageId: messageId,
            sourceSignature: oldSignature
        )
        let parsedSignaturesAfterUpdate = await ParsedEmailProvider.shared.debugCachedSourceSignatures(messageId: messageId)
        XCTAssertNil(oldArtifactsAfterUpdate)
        XCTAssertFalse(parsedSignaturesAfterUpdate.contains(oldSignature))
        await fulfillment(of: [sourceChangeExpectation], timeout: 1.0)
    }

    func testUpdateExistingMessage_invalidatesCachesWhenStoredHTMLBecomesNonCanonical() async throws {
        let contentHandler = HTMLContentHandler.shared
        let messageId = "message-html-source-noncanonical-\(UUID().uuidString)"
        let oldHTML = "<!DOCTYPE html><html><body><p>OLD_HTML_TOKEN</p></body></html>"
        let nonCanonicalHTML = """
        <!DOCTYPE html>
        <html>
        <head><style id="esc-plain-text-styles">.esc-plain-main { white-space: pre-wrap; }</style></head>
        <body><div class="esc-plain-main">Stable plain text</div></body>
        </html>
        """
        let plainText = "Stable plain text"
        let chatPreviewText = "Preferred chat preview"
        let snippet = "Stable snippet"
        let subject = "Stable subject"
        let senderEmail = "sender@example.com"

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        await RenderedMessageCache.shared.invalidate(messageId: messageId)
        await ParsedEmailProvider.shared.invalidate(messageId: messageId)
        defer {
            contentHandler.deleteHTML(for: messageId)
        }

        let oldURL = try XCTUnwrap(contentHandler.saveHTML(oldHTML, for: messageId))
        let oldSignature = try XCTUnwrap(
            contentHandler.canonicalHTMLSourceSignature(messageId: messageId, bodyStorageURI: oldURL.absoluteString)
        )
        XCTAssertNil(contentHandler.canonicalHTMLSourceSignature(for: nonCanonicalHTML))

        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId(messageId)
            .withSubject(subject)
            .withSender(email: senderEmail, name: "Sender")
            .withSnippet(snippet)
            .withBody(plainText)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.bodyStorageURI = oldURL.absoluteString
        existingMessage.chatPreviewText = chatPreviewText

        _ = await RenderedMessageCache.shared.wrappedOriginalHTML(
            messageId: messageId,
            sourceSignature: oldSignature,
            variantKey: "original-test"
        ) {
            "wrapped old html"
        }
        _ = await ParsedEmailProvider.shared.parsedEmail(
            messageId: messageId,
            sourceSignature: oldSignature,
            canonicalHTML: oldHTML
        )

        let sourceChangeExpectation = expectation(description: "HTML source change notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: HTMLContentLoader.contentSourceDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String == messageId else {
                return
            }
            XCTAssertNil(notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey])
            XCTAssertTrue(Thread.isMainThread)
            sourceChangeExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        var headers = ProcessedHeaders()
        headers.subject = subject
        headers.from = "Sender <\(senderEmail)>"
        headers.isFromMe = false
        let processedMessage = ProcessedMessage(
            id: messageId,
            gmThreadId: existingMessage.gmThreadId,
            snippet: snippet,
            cleanedSnippet: snippet,
            chatPreviewText: chatPreviewText,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nonCanonicalHTML,
            plainTextBody: plainText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: false,
            attachmentInfo: []
        )

        let htmlPersister = MessagePersister(
            htmlContentHandler: contentHandler,
            photoPrefetcher: { _ in }
        )
        let didUpdate = await htmlPersister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.bodyStorageURI, oldURL.absoluteString)
        XCTAssertEqual(existingMessage.bodyText, plainText)
        XCTAssertEqual(existingMessage.chatPreviewText, chatPreviewText)
        XCTAssertNil(contentHandler.canonicalHTMLSourceSignature(messageId: messageId, bodyStorageURI: oldURL.absoluteString))

        let oldArtifactsAfterUpdate = await RenderedMessageCache.shared.artifacts(
            messageId: messageId,
            sourceSignature: oldSignature
        )
        let parsedSignaturesAfterUpdate = await ParsedEmailProvider.shared.debugCachedSourceSignatures(messageId: messageId)
        XCTAssertNil(oldArtifactsAfterUpdate)
        XCTAssertFalse(parsedSignaturesAfterUpdate.contains(oldSignature))
        await fulfillment(of: [sourceChangeExpectation], timeout: 1.0)
    }

    func testUpdateExistingMessage_doesNotInvalidateCachesWhenStoredHTMLSourceSignatureIsUnchanged() async throws {
        let contentHandler = HTMLContentHandler.shared
        let messageId = "message-html-source-stable-\(UUID().uuidString)"
        let html = "<!DOCTYPE html><html><body><p>SAME_HTML_TOKEN</p></body></html>"
        let plainText = "Stable plain text"
        let chatPreviewText = "Preferred chat preview"
        let snippet = "Stable snippet"
        let subject = "Stable subject"
        let senderEmail = "sender@example.com"

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        await RenderedMessageCache.shared.invalidate(messageId: messageId)
        await ParsedEmailProvider.shared.invalidate(messageId: messageId)
        defer {
            contentHandler.deleteHTML(for: messageId)
        }

        let oldURL = try XCTUnwrap(contentHandler.saveHTML(html, for: messageId))
        let sourceSignature = try XCTUnwrap(
            contentHandler.canonicalHTMLSourceSignature(messageId: messageId, bodyStorageURI: oldURL.absoluteString)
        )

        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId(messageId)
            .withSubject(subject)
            .withSender(email: senderEmail, name: "Sender")
            .withSnippet(snippet)
            .withBody(plainText)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.bodyStorageURI = oldURL.absoluteString
        existingMessage.chatPreviewText = chatPreviewText

        _ = await RenderedMessageCache.shared.wrappedOriginalHTML(
            messageId: messageId,
            sourceSignature: sourceSignature,
            variantKey: "original-test"
        ) {
            "wrapped stable html"
        }
        _ = await ParsedEmailProvider.shared.parsedEmail(
            messageId: messageId,
            sourceSignature: sourceSignature,
            canonicalHTML: html
        )

        let noSourceChangeExpectation = expectation(description: "HTML source change notification not posted")
        noSourceChangeExpectation.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: HTMLContentLoader.contentSourceDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String == messageId else {
                return
            }
            noSourceChangeExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        var headers = ProcessedHeaders()
        headers.subject = subject
        headers.from = "Sender <\(senderEmail)>"
        headers.isFromMe = false
        let processedMessage = ProcessedMessage(
            id: messageId,
            gmThreadId: existingMessage.gmThreadId,
            snippet: snippet,
            cleanedSnippet: snippet,
            chatPreviewText: chatPreviewText,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: html,
            plainTextBody: plainText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: false,
            attachmentInfo: []
        )

        let htmlPersister = MessagePersister(
            htmlContentHandler: contentHandler,
            photoPrefetcher: { _ in }
        )
        let didUpdate = await htmlPersister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        let stableArtifactsAfterUpdate = await RenderedMessageCache.shared.artifacts(
            messageId: messageId,
            sourceSignature: sourceSignature
        )
        let stableParsedSignaturesAfterUpdate = await ParsedEmailProvider.shared.debugCachedSourceSignatures(messageId: messageId)
        XCTAssertNotNil(stableArtifactsAfterUpdate)
        XCTAssertTrue(stableParsedSignaturesAfterUpdate.contains(sourceSignature))
        await fulfillment(of: [noSourceChangeExpectation], timeout: 0.2)
    }

    func testSaveMessage_newHTMLMessage_savesHTMLOnce() async throws {
        var headers = ProcessedHeaders()
        headers.subject = "HTML message"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "new-html-message",
            gmThreadId: "new-html-thread",
            snippet: "HTML snippet",
            cleanedSnippet: "HTML snippet",
            internalDate: Date(),
            headers: headers,
            htmlBody: "<html><body><p>Hello</p></body></html>",
            plainTextBody: "Hello",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )
        let htmlSaveSpy = HTMLSaveSpy()
        let htmlPersister = MessagePersister(
            messageProcessor: StubMessageProcessor(processedMessage: processedMessage),
            saveHTML: { html, messageId in
                htmlSaveSpy.save(html, messageId: messageId)
            },
            photoPrefetcher: { _ in }
        )

        try await htmlPersister.saveMessage(
            GmailMessage(
                id: processedMessage.id,
                threadId: processedMessage.gmThreadId,
                labelIds: processedMessage.labelIds,
                snippet: processedMessage.snippet,
                historyId: nil,
                internalDate: "\(Int(processedMessage.internalDate.timeIntervalSince1970 * 1000))",
                payload: nil,
                sizeEstimate: nil
            ),
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        request.fetchLimit = 1

        let savedMessage = try XCTUnwrap(context.fetch(request).first)
        XCTAssertEqual(htmlSaveSpy.recordedCallCount, 1)
        XCTAssertEqual(savedMessage.bodyStorageURI, "file:///tmp/\(processedMessage.id).html")
    }

    func testSaveMessage_multipartAlternativePlainFirstPersistsHTML() async throws {
        let html = """
        <!DOCTYPE html><html><body><table><tr><td><a href="https://example.com/cta">Reserve now</a></td></tr></table></body></html>
        """
        let plainText = """
        https://tracking.example.com/a
        https://tracking.example.com/b
        Reserve now
        """
        let messageId = "persist-plain-first"
        let htmlSaveSpy = HTMLSaveSpy()
        let htmlPersister = MessagePersister(
            saveHTML: { html, messageId in
                htmlSaveSpy.save(html, messageId: messageId)
            },
            photoPrefetcher: { _ in }
        )

        try await htmlPersister.saveMessage(
            makeMultipartAlternativeMessage(
                id: messageId,
                plainText: plainText,
                html: html,
                plainFirst: true
            ),
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let savedMessage = try XCTUnwrap(fetchMessage(id: messageId))
        XCTAssertEqual(htmlSaveSpy.recordedCallCount, 1)
        XCTAssertEqual(htmlSaveSpy.recordedHTML, html)
        XCTAssertEqual(savedMessage.bodyStorageURI, "file:///tmp/\(messageId).html")
        XCTAssertEqual(savedMessage.bodyText, plainText)
    }

    func testSaveMessage_multipartAlternativeHTMLFirstPersistsHTML() async throws {
        let html = """
        <!DOCTYPE html><html><body><table><tr><td><img src="https://example.com/hero.jpg"><a href="https://example.com/cta">Reserve now</a></td></tr></table></body></html>
        """
        let plainText = """
        https://tracking.example.com/a
        https://tracking.example.com/b
        Reserve now
        """
        let messageId = "persist-html-first"
        let htmlSaveSpy = HTMLSaveSpy()
        let htmlPersister = MessagePersister(
            saveHTML: { html, messageId in
                htmlSaveSpy.save(html, messageId: messageId)
            },
            photoPrefetcher: { _ in }
        )

        try await htmlPersister.saveMessage(
            makeMultipartAlternativeMessage(
                id: messageId,
                plainText: plainText,
                html: html,
                plainFirst: false
            ),
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let savedMessage = try XCTUnwrap(fetchMessage(id: messageId))
        XCTAssertEqual(htmlSaveSpy.recordedCallCount, 1)
        XCTAssertEqual(htmlSaveSpy.recordedHTML, html)
        XCTAssertEqual(savedMessage.bodyStorageURI, "file:///tmp/\(messageId).html")
        XCTAssertEqual(savedMessage.bodyText, plainText)
    }

    func testCreateNewMessage_onBackgroundContext_persistsMessageAndConversation() async throws {
        let backgroundContext = testStack.newBackgroundContext()
        var headers = ProcessedHeaders()
        headers.subject = "Background sync message"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "background-create-message",
            gmThreadId: "background-thread-1",
            snippet: "Created on a background context",
            cleanedSnippet: "Created on a background context",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Created on a background context",
            labelIds: ["INBOX", "UNREAD"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: backgroundContext
        )
        try await backgroundContext.perform {
            try backgroundContext.save()
        }

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1

        let saved = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(saved.subject, "Background sync message")
        XCTAssertEqual(saved.conversation?.participantHash, calculateParticipantHash(from: ["sender@example.com"]))
        XCTAssertTrue(saved.isUnread)
    }

    func testUpdateExistingMessage_onBackgroundContext_persistsChanges() async throws {
        let conversation = ConversationBuilder.simple(in: context)
        _ = MessageBuilder()
            .withId("background-update-message")
            .inConversation(conversation)
            .build(in: context)
        try testStack.saveViewContext()

        let backgroundContext = testStack.newBackgroundContext()
        var headers = ProcessedHeaders()
        headers.subject = "Updated subject"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "background-update-message",
            gmThreadId: "thread-update-background",
            snippet: "Updated on background context",
            cleanedSnippet: "Updated on background context",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Updated on background context",
            labelIds: ["INBOX"],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: backgroundContext
        )
        XCTAssertTrue(didUpdate)

        try await backgroundContext.perform {
            try backgroundContext.save()
        }

        // The test context does not auto-merge sibling saves; refresh so the
        // registered message picks up the background context's changes.
        context.refreshAllObjects()

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1

        let saved = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(saved.snippet, "Updated on background context")
        XCTAssertTrue(saved.isNewsletter)
        XCTAssertFalse(saved.isUnread)
    }

    func testUpdateExistingMessage_preservesOutgoingLocalBodyWhenSyncBodyIsSnippetOnly() async throws {
        let conversation = ConversationBuilder.simple(in: context)
        let replyBody = """
        Can we please see alts for:

        Primary bedroom drapery
        Kitchen backsplash

        Thank you!
        """
        let existingMessage = MessageBuilder()
            .withId("outgoing-snippet-body-update")
            .withThreadId("thread-outgoing-snippet-body-update")
            .withSubject("Re: Finish options")
            .withSender(email: "me@example.com", name: "Me")
            .withSnippet("Can we please see alts for:")
            .withBody(replyBody)
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Finish options"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Can we please see alts for:",
            cleanedSnippet: "Can we please see alts for:",
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Can we please see alts for:",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.bodyText, replyBody)

        try testStack.saveViewContext()
        testStack.resetViewContext()

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1

        let saved = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(saved.bodyText, replyBody)
        XCTAssertEqual(saved.snippet, "Can we please see alts for:")
        XCTAssertEqual(saved.cleanedSnippet, "Can we please see alts for:")
    }

    // @MainActor: these two tests call ConversationRollupUpdater's
    // synchronous updateDisplayNameOnly, which writes managed-object
    // properties directly and so must run on the viewContext's queue. As a
    // nonisolated async test it ran on the cooperative pool and raced the
    // display-info notification handlers from neighboring tests — an
    // intermittent SIGSEGV in CI (_setLastSnapshot__ under setvfk).
    @MainActor
    func testUpdateExistingMessage_enrichesParticipantDisplayNameFromRefreshedFromHeader() async throws {
        let senderEmail = "info@bonbonwhims.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("Info")
            .build(in: context)
        let sender = PersonBuilder.emailOnly(senderEmail, in: context)
        addConversationParticipant(person: sender, to: conversation)
        let existingMessage = MessageBuilder()
            .withId("bonbonwhims-message")
            .withThreadId("bonbonwhims-thread")
            .withSender(email: senderEmail, name: nil)
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(person: sender, kind: .from, to: existingMessage)

        var headers = ProcessedHeaders()
        headers.subject = "Our Totally Spies! Collab is here"
        headers.from = "BONBONWHIMS <\(senderEmail)>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.senderName, "BONBONWHIMS")
        XCTAssertEqual(sender.displayName, "BONBONWHIMS")

        ConversationRollupUpdater().updateDisplayNameOnly(
            for: conversation,
            myEmail: "kmthau@gmail.com"
        )
        XCTAssertEqual(conversation.displayName, "BONBONWHIMS")
    }

    @MainActor
    func testUpdateExistingMessage_replacesAddressDerivedParticipantDisplayName() async throws {
        let senderEmail = "bonbonwhims@example.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("Bonbonwhims")
            .build(in: context)
        let sender = PersonBuilder()
            .withEmail(senderEmail)
            .withDisplayName("Bonbonwhims")
            .build(in: context)
        addConversationParticipant(person: sender, to: conversation)
        let existingMessage = MessageBuilder()
            .withId("bonbonwhims-address-derived-message")
            .withThreadId("bonbonwhims-address-derived-thread")
            .withSender(email: senderEmail, name: nil)
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(person: sender, kind: .from, to: existingMessage)

        var headers = ProcessedHeaders()
        headers.subject = "Brand casing should win"
        headers.from = "BONBONWHIMS <\(senderEmail)>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(sender.displayName, "BONBONWHIMS")

        ConversationRollupUpdater().updateDisplayNameOnly(
            for: conversation,
            myEmail: "kmthau@gmail.com"
        )
        XCTAssertEqual(conversation.displayName, "BONBONWHIMS")
    }

    func testUpdateExistingMessage_tracksAllConversationsSharingRenamedParticipant() async throws {
        await ModificationTracker.shared.reset()

        let senderEmail = "info@bonbonwhims.com"
        let firstConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("Info")
            .build(in: context)
        let secondConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("Info")
            .withSnippet("Keep this local snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_000_000))
            .build(in: context)
        let sender = PersonBuilder.emailOnly(senderEmail, in: context)
        addConversationParticipant(person: sender, to: firstConversation)
        addConversationParticipant(person: sender, to: secondConversation)
        let existingMessage = MessageBuilder()
            .withId("bonbonwhims-shared-person-message")
            .withThreadId("bonbonwhims-shared-person-thread")
            .withSender(email: senderEmail, name: nil)
            .inConversation(firstConversation)
            .build(in: context)
        addMessageParticipant(person: sender, kind: .from, to: existingMessage)
        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Our Totally Spies! Collab is here"
        headers.from = "BONBONWHIMS <\(senderEmail)>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )
        let transaction = await ModificationTracker.shared.beginTransaction()

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            modificationTransaction: transaction,
            in: context
        )

        XCTAssertTrue(didUpdate)
        let modifiedConversations = await ModificationTracker.shared.modifiedConversations(in: transaction)
        let trackedDisplayNameOnlyConversations = await ModificationTracker.shared
            .displayNameOnlyConversations(in: transaction)
        let displayNameOnlyConversations = trackedDisplayNameOnlyConversations.subtracting(modifiedConversations)
        XCTAssertEqual(modifiedConversations, Set([firstConversation.objectID]))
        XCTAssertEqual(displayNameOnlyConversations, Set([secondConversation.objectID]))

        await ConversationRollupUpdater().updateRollupsForModified(
            conversationIDs: modifiedConversations,
            in: context,
            myEmail: "kmthau@gmail.com"
        )
        await ConversationRollupUpdater().updateDisplayNamesForConversations(
            conversationIDs: displayNameOnlyConversations,
            in: context,
            myEmail: "kmthau@gmail.com"
        )
        XCTAssertEqual(firstConversation.displayName, "BONBONWHIMS")
        XCTAssertEqual(secondConversation.displayName, "BONBONWHIMS")
        XCTAssertEqual(secondConversation.snippet, "Keep this local snippet")
        XCTAssertEqual(secondConversation.lastMessageDate, Date(timeIntervalSince1970: 1_700_000_000))

        await ModificationTracker.shared.reset()
    }

    func testUpdateExistingMessage_postsPersonDisplayInfoChangeAfterSaveWhenParticipantNameImproves() async throws {
        let senderEmail = "info@bonbonwhims.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("Info")
            .build(in: context)
        let sender = PersonBuilder.emailOnly(senderEmail, in: context)
        addConversationParticipant(person: sender, to: conversation)
        let existingMessage = MessageBuilder()
            .withId("bonbonwhims-notification-message")
            .withThreadId("bonbonwhims-notification-thread")
            .withSender(email: senderEmail, name: nil)
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(person: sender, kind: .from, to: existingMessage)
        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Our Totally Spies! Collab is here"
        headers.from = "BONBONWHIMS <\(senderEmail)>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let preSaveNotificationExpectation = expectation(description: "person display info notification not posted before save")
        preSaveNotificationExpectation.isInverted = true
        let notificationExpectation = expectation(description: "person display info notification posted after save")
        let notificationRecorder = PersonDisplayInfoNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            switch notificationRecorder.record(notification: notification, senderEmail: senderEmail) {
            case .unrelated:
                return
            case .beforeSave:
                preSaveNotificationExpectation.fulfill()
            case .afterSave:
                notificationExpectation.fulfill()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        await fulfillment(of: [preSaveNotificationExpectation], timeout: 0.2)

        notificationRecorder.markSaved()
        try context.save()
        await fulfillment(of: [notificationExpectation], timeout: 1.0)
        XCTAssertEqual(notificationRecorder.notifiedEmails, [senderEmail])
    }

    func testUpdateExistingMessage_postsPersonDisplayInfoChangeAfterSaveWhenSenderHeaderNameBecomesUnusable() async throws {
        let senderEmail = "john.smith@example.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [senderEmail]))
            .withDisplayName("John Smith")
            .build(in: context)
        let sender = PersonBuilder()
            .withEmail(senderEmail)
            .withDisplayName("Acme Team")
            .build(in: context)
        addConversationParticipant(person: sender, to: conversation)
        let existingMessage = MessageBuilder()
            .withId("sender-header-unusable-message")
            .withThreadId("sender-header-unusable-thread")
            .withSender(email: senderEmail, name: "Acme Team")
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(person: sender, kind: .from, to: existingMessage)
        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Header name regressed"
        headers.from = "john.smith <\(senderEmail)>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: true,
            hasAttachments: false,
            attachmentInfo: []
        )

        let preSaveNotificationExpectation = expectation(description: "person display info notification not posted before save")
        preSaveNotificationExpectation.isInverted = true
        let notificationExpectation = expectation(description: "person display info notification posted after save")
        let notificationRecorder = PersonDisplayInfoNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            switch notificationRecorder.record(notification: notification, senderEmail: senderEmail) {
            case .unrelated:
                return
            case .beforeSave:
                preSaveNotificationExpectation.fulfill()
            case .afterSave:
                notificationExpectation.fulfill()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.senderName, "john.smith")
        await fulfillment(of: [preSaveNotificationExpectation], timeout: 0.2)

        notificationRecorder.markSaved()
        try context.save()
        await fulfillment(of: [notificationExpectation], timeout: 1.0)
        XCTAssertEqual(notificationRecorder.notifiedEmails, [senderEmail])
    }

    /// The optimistic send path mirrors the outgoing MIME's From identity so
    /// the sent message's sync echo compares equal here. This pins the
    /// load-bearing half of that contract: an echo whose From matches the
    /// stored sender fields must not post a display-info change, which would
    /// refresh (and briefly collapse) every visible chat bubble right after
    /// a send.
    func testUpdateExistingMessage_sentEchoWithMirroredFromIdentityDoesNotPostDisplayInfoChange() async throws {
        let myEmail = "me@example.com"
        let friendEmail = "friend@example.com"
        let conversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [friendEmail]))
            .withDisplayName("Friend")
            .build(in: context)
        let friend = PersonBuilder.emailOnly(friendEmail, in: context)
        addConversationParticipant(person: friend, to: conversation)
        let optimisticMessage = MessageBuilder()
            .withId("sent-echo-mirrored-identity-message")
            .withThreadId("sent-echo-mirrored-identity-thread")
            .withSender(email: myEmail, name: "Me Example")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Plans"
        headers.from = "Me Example <\(myEmail)>"
        headers.to = [EmailAddress(email: friendEmail, displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: optimisticMessage.id,
            gmThreadId: optimisticMessage.gmThreadId,
            snippet: optimisticMessage.snippet,
            cleanedSnippet: optimisticMessage.cleanedSnippet,
            internalDate: optimisticMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: optimisticMessage.bodyText,
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let unexpectedNotification = expectation(
            description: "a matching sent echo must not post a self display-info change"
        )
        unexpectedNotification.isInverted = true
        let notificationRecorder = PersonDisplayInfoNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if notificationRecorder.record(
                notification: notification,
                senderEmail: myEmail
            ) != .unrelated {
                unexpectedNotification.fulfill()
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationRecorder.markSaved()

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(optimisticMessage.senderEmail, myEmail)
        XCTAssertEqual(optimisticMessage.senderName, "Me Example")
        // Deterministic check: a mismatching identity is STAGED synchronously
        // in the context's userInfo before any save-driven async post.
        let stagedEmails = context.userInfo["personDisplayInfoDidChange.pendingEmails"] as? [String] ?? []
        XCTAssertFalse(
            stagedEmails.contains(myEmail),
            "The sent echo staged a self display-info change: \(stagedEmails)"
        )
        try context.save()
        await fulfillment(of: [unexpectedNotification], timeout: 0.5)
    }

    func testCreateNewMessage_sameGmThreadIdWithParticipantDrift_createsNewConversation() async throws {
        let threadId = "thread-join-123"
        let existingConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["rirc@advantagetennisclubs.com"]))
            .build(in: context)
        _ = MessageBuilder()
            .withId("existing-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: private lesson"
        headers.from = "RIRC <RIRC@advantagetennisclubs.com>"
        headers.to = [
            EmailAddress(email: "kmthau@gmail.com", displayName: nil),
            EmailAddress(email: "assistant@advantagetennisclubs.com", displayName: nil)
        ]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "new-message",
            gmThreadId: threadId,
            snippet: "Wonderful. Thank you so much.",
            cleanedSnippet: "Wonderful. Thank you so much.",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Wonderful. Thank you so much.",
            labelIds: ["INBOX", "UNREAD"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("kmthau@gmail.com")],
            in: context
        )

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2, "Participant drift on the same Gmail thread must route to its own participant-keyed conversation")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "new-message")
        fetch.fetchLimit = 1
        let saved = try XCTUnwrap(context.fetch(fetch).first)

        XCTAssertNotEqual(saved.conversation?.objectID, existingConversation.objectID)
        XCTAssertEqual(
            saved.conversation?.participantHash,
            calculateParticipantHash(from: [
                "assistant@advantagetennisclubs.com",
                "rirc@advantagetennisclubs.com"
            ]),
            "New conversation should be keyed by the drifted participant set"
        )
    }

    // Strict participant-set routing: the reply's exact set {friend} matches the
    // one-to-one conversation's participantHash, so it lands there even though the
    // group-split conversation is the newest one on the same Gmail thread.
    func testCreateNewMessage_nonForwardedReplyReusesRegularConversationWhenForwardedSplitIsNewest() async throws {
        let threadId = "thread-forwarded-split-newest"
        let regularConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .build(in: context)
        let forwardedConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [
                "friend@example.com",
                "teammate@example.com"
            ]))
            .build(in: context)

        _ = MessageBuilder()
            .withId("regular-thread-message")
            .withThreadId(threadId)
            .withSubject("Re: Team dinner")
            .withDate(Date(timeIntervalSince1970: 1_700_000_000))
            .inConversation(regularConversation)
            .build(in: context)

        _ = MessageBuilder()
            .withId("forwarded-thread-message")
            .withThreadId(threadId)
            .withSubject("Fwd: Team dinner")
            .withDate(Date(timeIntervalSince1970: 1_700_000_120))
            .inConversation(forwardedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Team dinner"
        headers.from = "Friend <friend@example.com>"
        headers.to = [EmailAddress(email: "me@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "new-regular-reply",
            gmThreadId: threadId,
            snippet: "Sounds good to me.",
            cleanedSnippet: "Sounds good to me.",
            internalDate: Date(timeIntervalSince1970: 1_700_000_240),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Sounds good to me.",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", processedMessage.id)
        fetch.fetchLimit = 1
        let saved = try XCTUnwrap(context.fetch(fetch).first)

        XCTAssertEqual(saved.conversation?.objectID, regularConversation.objectID)
        XCTAssertNotEqual(saved.conversation?.objectID, forwardedConversation.objectID)
        XCTAssertEqual(try context.count(for: Conversation.fetchRequest()), 2)
    }

    // Forward heuristics no longer drive routing: this split happens purely because
    // the forward's participant set {brynn, kristine} differs from the existing
    // one-to-one {brynn} conversation on the same Gmail thread.
    func testCreateNewMessage_forwardedSubjectWithDifferentParticipantSet_createsNewConversation() async throws {
        let threadId = "thread-forward-123"
        let existingConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["brynn@example.com"]))
            .visible()
            .recentlyActive()
            .build(in: context)
        _ = MessageBuilder()
            .withId("existing-forward-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Fwd: Mario Spina"
        headers.from = "Brynn Putnam <brynn@example.com>"
        headers.to = [
            EmailAddress(email: "kristine@example.com", displayName: "Kristine"),
            EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")
        ]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "forwarded-message",
            gmThreadId: threadId,
            snippet: "Hi Kristine, can you take a look?",
            cleanedSnippet: "Hi Kristine, can you take a look?",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Hi Kristine, can you take a look?",
            labelIds: [],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("kmthau@gmail.com")],
            in: context
        )

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2, "A forward whose participant set differs should create a new participant-keyed conversation")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "forwarded-message")
        fetch.fetchLimit = 1
        let saved = try context.fetch(fetch).first

        XCTAssertNotEqual(saved?.conversation?.objectID, existingConversation.objectID)
        XCTAssertEqual(
            saved?.conversation?.participantHash,
            calculateParticipantHash(from: ["brynn@example.com", "kristine@example.com"]),
            "New conversation should be keyed by the forward's sender+recipient participant set"
        )
    }

    // Inverse of the old forward-marker split: forward markers in the body are
    // ignored by routing. When the participant set is unchanged, the message joins
    // the existing same-set conversation; a split only happens when the set differs.
    func testCreateNewMessage_forwardedMarkerInBodyWithSameParticipantSet_joinsExistingConversation() async throws {
        let threadId = "thread-forward-body-marker-123"
        let existingConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["erin.hardy@adviceperiod.com"]))
            .visible()
            .recentlyActive()
            .build(in: context)
        _ = MessageBuilder()
            .withId("existing-thread-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Deposit Notification (Deposit Declined)"
        headers.from = "Erin Hardy <erin.hardy@adviceperiod.com>"
        headers.to = [EmailAddress(email: "kmthau@gmail.com", displayName: "Kevin Thau")]
        headers.isFromMe = false

        let plainText = """
        Hi Kevin,

        Yes, I'll reach out to them about this. Will circle back.

        --- original message ---
        On February 23, 2026, 8:21 PM PST kmthau@gmail.com wrote:
        ---------- Forwarded message ---------
        """

        let processedMessage = ProcessedMessage(
            id: "forwarded-marker-reply-message",
            gmThreadId: threadId,
            snippet: "Yes, I'll reach out to them about this. Will circle back.",
            cleanedSnippet: "Yes, I'll reach out to them about this. Will circle back.",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: plainText,
            labelIds: [],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("kmthau@gmail.com")],
            in: context
        )

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1, "A forward-marker body with an unchanged participant set must join the existing same-set conversation")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "forwarded-marker-reply-message")
        fetch.fetchLimit = 1
        let saved = try context.fetch(fetch).first

        XCTAssertEqual(saved?.conversation?.objectID, existingConversation.objectID)
    }

    func testCreateNewMessage_sentOnlyMessageInArchivedThread_reactivatesConversation() async throws {
        let threadId = "thread-archived-sent-only"
        // Strict routing matches by participantHash only, so the archived seed must
        // carry the hash of the outgoing message's participant set {friend}.
        let archivedConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .withSnippet("Old archived snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_100_000))
            .archived()
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("seed-archived-message")
            .withThreadId(threadId)
            .inConversation(archivedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Archived thread"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "sent-only-archived-thread-message",
            gmThreadId: threadId,
            snippet: "Sent from another client",
            cleanedSnippet: "Sent from another client",
            internalDate: Date(timeIntervalSince1970: 1_700_100_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Sent from another client",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "sent-only-archived-thread-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(savedMessage.conversation?.objectID, archivedConversation.objectID)
    }

    func testCreateNewMessage_sameGmThreadIdWithNilParticipantHash_createsNewConversationWithoutBackfill() async throws {
        let threadId = "thread-nil-participant-hash"
        // Legacy conversation without a participantHash: strict routing never
        // reuses it via the shared gmThreadId and never backfills the hash.
        let existingConversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_150_000))
            .build(in: context)

        _ = MessageBuilder()
            .withId("seed-nil-hash-message")
            .withThreadId(threadId)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Existing thread"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "nil-participant-hash-message",
            gmThreadId: threadId,
            snippet: "Latest snippet",
            cleanedSnippet: "Latest snippet",
            internalDate: Date(timeIntervalSince1970: 1_700_150_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Latest snippet",
            labelIds: ["INBOX"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "nil-participant-hash-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)

        XCTAssertNotEqual(
            savedMessage.conversation?.objectID,
            existingConversation.objectID,
            "A nil-hash legacy conversation must not be reused just because the gmThreadId matches"
        )
        XCTAssertEqual(
            savedMessage.conversation?.participantHash,
            calculateParticipantHash(from: ["sender@example.com"])
        )
        XCTAssertNil(
            existingConversation.participantHash,
            "The router must not backfill participantHash onto legacy conversations"
        )
        XCTAssertEqual(try context.count(for: Conversation.fetchRequest()), 2)
    }

    func testCreateNewMessage_sentOnlyMessageInParticipantFallback_reactivatesConversation() async throws {
        let participantHash = calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withSnippet("Old archived snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_200_000))
            .archived()
            .setHidden()
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "New outbound"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "sent-only-fallback-message",
            gmThreadId: "thread-without-local-match",
            snippet: "Outbound from another client",
            cleanedSnippet: "Outbound from another client",
            internalDate: Date(timeIntervalSince1970: 1_700_200_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Outbound from another client",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        XCTAssertNil(archivedConversation.archivedAt)
        XCTAssertFalse(archivedConversation.hidden)

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "sent-only-fallback-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertEqual(savedMessage.conversation?.objectID, archivedConversation.objectID)
    }

    func testCreateNewMessage_sentOnlyMessageWithParticipantDrift_createsNewActiveConversation() async throws {
        let threadId = "thread-sent-participant-drift"
        let archivedConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .withSnippet("Archived snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_210_000))
            .archived()
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("seed-thread-message")
            .withThreadId(threadId)
            .inConversation(archivedConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Archived thread"
        headers.from = "Me <me@example.com>"
        headers.to = [
            EmailAddress(email: "friend@example.com", displayName: nil),
            EmailAddress(email: "assistant@example.com", displayName: nil)
        ]
        headers.isFromMe = true

        let processedMessage = ProcessedMessage(
            id: "sent-participant-drift-message",
            gmThreadId: threadId,
            snippet: "Outbound from another client",
            cleanedSnippet: "Outbound from another client",
            internalDate: Date(timeIntervalSince1970: 1_700_210_120),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Outbound from another client",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("me@example.com")],
            in: context
        )

        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2, "A sent message to a drifted participant set must start its own conversation, not reuse the same-thread one")

        let fetch = Message.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", "sent-participant-drift-message")
        fetch.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(fetch).first)
        XCTAssertNotEqual(savedMessage.conversation?.objectID, archivedConversation.objectID)
        XCTAssertEqual(
            savedMessage.conversation?.participantHash,
            calculateParticipantHash(from: ["assistant@example.com", "friend@example.com"])
        )
        XCTAssertNil(savedMessage.conversation?.archivedAt, "The drifted-set conversation should start active")

        XCTAssertNotNil(archivedConversation.archivedAt, "The archived single-participant conversation must keep archivedAt")
        XCTAssertTrue(archivedConversation.hidden)
    }

    func testCreateNewMessage_updatesConversationListIndicatorsImmediately() async throws {
        _ = LabelBuilder.inboxLabel(in: context)
        _ = LabelBuilder.unreadLabel(in: context)

        let threadId = "thread-fast-list-update"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(120)

        // Seed the participantHash of the incoming sender so strict routing
        // resolves the incoming message into this conversation.
        let existingConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["sender@example.com"]))
            .withSnippet("Old snippet")
            .withLastMessageDate(oldDate)
            .withUnreadCount(0)
            .hasInboxMessages(false)
            .archived()
            .setHidden()
            .build(in: context)

        _ = MessageBuilder()
            .withId("existing-seed-message")
            .withThreadId(threadId)
            .withDate(oldDate)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.subject = "Re: Fast list update"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "incoming-fast-list-message",
            gmThreadId: threadId,
            snippet: "Raw incoming snippet",
            cleanedSnippet: "Clean incoming snippet",
            internalDate: newDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Body",
            labelIds: ["INBOX", "UNREAD"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        XCTAssertEqual(existingConversation.inboxUnreadCount, 1)
        XCTAssertTrue(existingConversation.hasInbox)
        XCTAssertEqual(existingConversation.latestInboxDate, newDate)
        XCTAssertEqual(existingConversation.lastMessageDate, newDate)
        XCTAssertEqual(existingConversation.snippet, "Clean incoming snippet")
        XCTAssertNil(existingConversation.archivedAt)
        XCTAssertFalse(existingConversation.hidden)
    }

    func testCreateNewMessage_doesNotClearExistingConversationSnippetWhenPreviewIsMissing() async throws {
        let threadId = "thread-fast-list-missing-preview"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(120)

        // Seed the participantHash of the incoming sender so strict routing
        // resolves the incoming message into this conversation.
        let existingConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["sender@example.com"]))
            .withSnippet("Old row preview")
            .withLastMessageDate(oldDate)
            .visible()
            .build(in: context)

        _ = MessageBuilder()
            .withId("existing-missing-preview-seed")
            .withThreadId(threadId)
            .withDate(oldDate)
            .inConversation(existingConversation)
            .build(in: context)

        try testStack.saveViewContext()

        var headers = ProcessedHeaders()
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "incoming-missing-preview-message",
            gmThreadId: threadId,
            snippet: nil,
            cleanedSnippet: nil,
            chatPreviewText: nil,
            internalDate: newDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: nil,
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        XCTAssertEqual(existingConversation.lastMessageDate, newDate)
        XCTAssertEqual(existingConversation.snippet, "Old row preview")
    }

    func testUpdateExistingMessage_preservesPendingLocalMailboxStateWhileRefreshingCanonicalMetadata() async throws {
        let inboxLabel = LabelBuilder.inboxLabel(in: context)
        let unreadLabel = LabelBuilder.unreadLabel(in: context)

        let conversation = ConversationBuilder()
            .withSnippet("Local snippet")
            .withLastMessageDate(Date(timeIntervalSince1970: 1_700_300_000))
            .withUnreadCount(1)
            .hasInboxMessages(true)
            .visible()
            .build(in: context)
        let existingMessage = MessageBuilder()
            .withId("pending-local-state-message")
            .withThreadId("old-thread-id")
            .withSubject("Old subject")
            .withSender(email: "old@example.com", name: "Old Sender")
            .withSnippet("Local snippet")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.addToLabels(inboxLabel)
        existingMessage.addToLabels(unreadLabel)
        existingMessage.isUnread = true
        existingMessage.isFromMe = false
        existingMessage.localModifiedAt = Date()

        var headers = ProcessedHeaders()
        headers.subject = "Updated subject"
        headers.from = "Me <me@example.com>"
        headers.to = [EmailAddress(email: "friend@example.com", displayName: nil)]
        headers.isFromMe = true
        headers.messageId = "<server-message-id@example.com>"
        headers.references = ["<ref-1@example.com>", "<ref-2@example.com>"]

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: "new-thread-id",
            snippet: "Server snippet",
            cleanedSnippet: "Server snippet",
            internalDate: existingMessage.internalDate,
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Updated body",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertTrue(existingMessage.isUnread, "Pending local read/unread changes should win over server state")
        XCTAssertTrue(existingMessage.labels?.contains(where: { $0.id == "INBOX" }) ?? false)
        XCTAssertEqual(existingMessage.gmThreadId, "new-thread-id")
        XCTAssertEqual(existingMessage.subject, "Updated subject")
        XCTAssertTrue(existingMessage.isFromMe)
        XCTAssertEqual(existingMessage.messageIdValue, "<server-message-id@example.com>")
        XCTAssertEqual(existingMessage.referencesValue, "<ref-1@example.com> <ref-2@example.com>")
        XCTAssertEqual(existingMessage.senderEmailValue, "me@example.com")
        XCTAssertEqual(existingMessage.senderNameValue, "Me")
    }

    func testUpdateExistingMessage_updatesConversationUnreadIndicatorsImmediately() async {
        let inboxLabel = LabelBuilder.inboxLabel(in: context)
        let unreadLabel = LabelBuilder.unreadLabel(in: context)
        let messageDate = Date(timeIntervalSince1970: 1_700_001_000)

        let conversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(messageDate)
            .hasInboxMessages(true)
            .withUnreadCount(1)
            .build(in: context)

        let existingMessage = MessageBuilder()
            .withId("existing-label-update-message")
            .withDate(messageDate)
            .withSnippet("Old message snippet")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.isUnread = true
        existingMessage.addToLabels(inboxLabel)
        existingMessage.addToLabels(unreadLabel)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: "Updated raw snippet",
            cleanedSnippet: "Updated clean snippet",
            internalDate: messageDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: ["INBOX"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertTrue(conversation.hasInbox)
        XCTAssertEqual(conversation.latestInboxDate, messageDate)
        XCTAssertEqual(conversation.snippet, "Updated clean snippet")
    }

    func testUpdateExistingMessage_removingInboxLabelRecomputesConversationInboxIndicators() async {
        let inboxLabel = LabelBuilder.inboxLabel(in: context)
        let messageDate = Date(timeIntervalSince1970: 1_700_002_000)

        let conversation = ConversationBuilder()
            .withSnippet("Old snippet")
            .withLastMessageDate(messageDate)
            .hasInboxMessages(true)
            .withUnreadCount(0)
            .build(in: context)

        let existingMessage = MessageBuilder()
            .withId("existing-remove-inbox-message")
            .withDate(messageDate)
            .inConversation(conversation)
            .build(in: context)
        existingMessage.isUnread = false
        existingMessage.addToLabels(inboxLabel)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: messageDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
    }

    func testUpdateExistingMessage_mergesMissingServerAttachmentsForOptimisticSentMessage() async {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-attachment-merge")
            .inConversation(conversation)
            .build(in: context)
        existingMessage.hasAttachments = true

        _ = AttachmentBuilder()
            .withId("local_inline_existing")
            .withFilename("optimistic-inline.png")
            .withMimeType("image/png")
            .withContentId("ii_mm3y7cq08")
            .downloaded()
            .forMessage(existingMessage)
            .build(in: context)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: true,
            attachmentInfo: [
                // Same CID as optimistic local attachment; should dedupe.
                AttachmentInfo(
                    id: "real_attachment_1",
                    filename: "inline-existing.png",
                    mimeType: "image/png",
                    size: 120,
                    contentId: "<ii_mm3y7cq08>"
                ),
                AttachmentInfo(
                    id: "real_attachment_2",
                    filename: "inline-2.png",
                    mimeType: "image/png",
                    size: 121,
                    contentId: "ii_19c9bbffa4da5b773191"
                ),
                AttachmentInfo(
                    id: "real_attachment_3",
                    filename: "inline-3.png",
                    mimeType: "image/png",
                    size: 122,
                    contentId: "ii_19c9bbffa4d86c910832"
                )
            ]
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)

        let attachments = existingMessage.attachmentsArray
        XCTAssertEqual(attachments.count, 3)

        let normalizedCIDs = attachments.compactMap { attachment -> String? in
            guard let contentId = attachment.contentId else { return nil }
            return contentId
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
                .lowercased()
        }

        XCTAssertEqual(normalizedCIDs.filter { $0 == "ii_mm3y7cq08" }.count, 1)
        XCTAssertTrue(normalizedCIDs.contains("ii_19c9bbffa4da5b773191"))
        XCTAssertTrue(normalizedCIDs.contains("ii_19c9bbffa4d86c910832"))
    }

    func testUpdateExistingMessage_removesDuplicateInlineAttachmentsSharingContentID() async {
        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId("message-inline-cid-dedup")
            .inConversation(conversation)
            .withAttachments()
            .build(in: context)
        existingMessage.hasAttachments = true

        let downloadedDuplicate = AttachmentBuilder()
            .withId("dup-inline-downloaded")
            .withFilename("IMG_6161.jpeg")
            .withMimeType("image/jpeg")
            .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
            .withLocalURL("Attachments/dup-inline-downloaded.jpg")
            .withPreviewURL("Previews/dup-inline-downloaded.jpg")
            .withByteSize(350_000)
            .downloaded()
            .forMessage(existingMessage)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("dup-inline-queued-1")
            .withFilename("IMG_6161.jpeg")
            .withMimeType("image/jpeg")
            .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
            .withByteSize(350_000)
            .queued()
            .forMessage(existingMessage)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("dup-inline-queued-2")
            .withFilename("IMG_6161.jpeg")
            .withMimeType("image/jpeg")
            .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
            .withByteSize(350_000)
            .queued()
            .forMessage(existingMessage)
            .build(in: context)

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: true,
            attachmentInfo: []
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.attachmentsArray.count, 1)
        XCTAssertEqual(existingMessage.attachmentsArray.first?.id, downloadedDuplicate.id)
        XCTAssertEqual(existingMessage.attachmentsArray.first?.localURL, "Attachments/dup-inline-downloaded.jpg")
    }

    func testUpdateExistingMessage_reconcilesOptimisticLocalRegularAttachmentWithoutDuplication() async throws {
        let testID = UUID().uuidString
        let messageID = "message-regular-attachment-merge-\(testID)"
        let localAttachmentID = "local_photo_attachment_\(testID)"
        let remoteAttachmentID = "real_attachment_\(testID)"
        let originalData = Data("offline-original-\(testID)".utf8)
        let previewData = Data("offline-preview-\(testID)".utf8)
        let localOriginalPath = AttachmentPaths.originalPath(idOrUUID: localAttachmentID, ext: "jpg")
        let localPreviewPath = AttachmentPaths.previewPath(idOrUUID: localAttachmentID)
        let remoteOriginalPath = AttachmentPaths.originalPath(
            messageId: messageID,
            attachmentId: remoteAttachmentID,
            ext: "jpg"
        )
        let remotePreviewPath = AttachmentPaths.previewPath(
            messageId: messageID,
            attachmentId: remoteAttachmentID
        )
        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(originalData, to: localOriginalPath))
        XCTAssertTrue(AttachmentPaths.saveData(previewData, to: localPreviewPath))
        defer {
            AttachmentPaths.deleteFile(at: localOriginalPath)
            AttachmentPaths.deleteFile(at: localPreviewPath)
            AttachmentPaths.deleteFile(at: remoteOriginalPath)
            AttachmentPaths.deleteFile(at: remotePreviewPath)
        }

        let conversation = ConversationBuilder.simple(in: context)
        let existingMessage = MessageBuilder()
            .withId(messageID)
            .inConversation(conversation)
            .withAttachments()
            .build(in: context)

        let optimisticAttachment = AttachmentBuilder()
            .withId(localAttachmentID)
            .withFilename("photo.jpg")
            .withMimeType("image/jpeg")
            .withByteSize(2_048)
            .withLocalURL(localOriginalPath)
            .withPreviewURL(localPreviewPath)
            .forMessage(existingMessage)
            .build(in: context)
        optimisticAttachment.state = .uploaded

        let processedMessage = ProcessedMessage(
            id: existingMessage.id,
            gmThreadId: existingMessage.gmThreadId,
            snippet: existingMessage.snippet,
            cleanedSnippet: existingMessage.cleanedSnippet,
            internalDate: existingMessage.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: existingMessage.bodyText,
            labelIds: [],
            isUnread: existingMessage.isUnread,
            isNewsletter: existingMessage.isNewsletter,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: remoteAttachmentID,
                    filename: "photo.jpg",
                    mimeType: "image/jpeg",
                    size: 2_048,
                    contentId: nil
                )
            ]
        )

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(existingMessage.attachmentsArray.count, 1)

        let savedAttachment = try XCTUnwrap(existingMessage.attachmentsArray.first)
        XCTAssertEqual(savedAttachment.id, remoteAttachmentID)
        XCTAssertEqual(savedAttachment.localURL, remoteOriginalPath)
        XCTAssertEqual(savedAttachment.previewURL, remotePreviewPath)
        XCTAssertEqual(savedAttachment.readableLocalURLValue, remoteOriginalPath)
        XCTAssertEqual(savedAttachment.readablePreviewURLValue, remotePreviewPath)
        XCTAssertEqual(AttachmentPaths.loadData(from: savedAttachment.readableLocalURLValue), originalData)
        XCTAssertEqual(AttachmentPaths.loadData(from: savedAttachment.readablePreviewURLValue), previewData)
        XCTAssertFalse(savedAttachment.needsRedownload)
        XCTAssertEqual(savedAttachment.state, .uploaded)
    }

    func testCreateNewMessage_inlineDataAttachment_isPersistedAsDownloaded() async throws {
        let inlineImageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="))

        var headers = ProcessedHeaders()
        headers.subject = "Inline attachment"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "recipient@example.com", displayName: nil)]
        headers.isFromMe = false

        let processedMessage = ProcessedMessage(
            id: "inline-data-message",
            gmThreadId: "inline-data-thread",
            snippet: "See image",
            cleanedSnippet: "See image",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "See image",
            labelIds: ["INBOX"],
            isUnread: true,
            isNewsletter: false,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: "local_inline_test_attachment",
                    filename: "inline.png",
                    mimeType: "image/png",
                    size: inlineImageData.count,
                    contentId: "inline-test",
                    inlineData: inlineImageData
                )
            ]
        )

        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: [normalizedEmail("recipient@example.com")],
            in: context
        )

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", "inline-data-message")
        request.fetchLimit = 1
        let savedMessage = try XCTUnwrap(context.fetch(request).first)
        let savedAttachment = try XCTUnwrap(savedMessage.attachmentsArray.first)

        XCTAssertEqual(savedMessage.attachmentsArray.count, 1)
        XCTAssertEqual(savedAttachment.state, .downloaded)
        XCTAssertNotNil(savedAttachment.localURL)
        XCTAssertNotNil(savedAttachment.previewURL)
        XCTAssertEqual(savedAttachment.contentId, "inline-test")
        XCTAssertEqual(AttachmentPaths.loadData(from: savedAttachment.localURL), inlineImageData)

        AttachmentPaths.deleteFile(at: savedAttachment.localURL)
        AttachmentPaths.deleteFile(at: savedAttachment.previewURL)
    }

    func testUpdateExistingMessage_migratesLegacySynthesizedInlineDataToCompositePath() async throws {
        let inlineImageData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII=")
        )
        let conversation = ConversationBuilder.simple(in: context)
        let message = MessageBuilder()
            .withId("inline-data-migration-message")
            .inConversation(conversation)
            .withAttachments()
            .build(in: context)
        let attachmentID = "local_inline_migration"
        let legacyPath = AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "png")
        let legacyPreviewPath = AttachmentPaths.previewPath(idOrUUID: attachmentID)
        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(Data("stale".utf8), to: legacyPath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("stale-preview".utf8), to: legacyPreviewPath))

        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withContentId("inline-migration")
            .withLocalURL(legacyPath)
            .withPreviewURL(legacyPreviewPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let processedMessage = ProcessedMessage(
            id: message.id,
            gmThreadId: message.gmThreadId,
            snippet: message.snippet,
            cleanedSnippet: message.cleanedSnippet,
            internalDate: message.internalDate,
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: message.bodyText,
            labelIds: [],
            isUnread: message.isUnread,
            isNewsletter: message.isNewsletter,
            hasAttachments: true,
            attachmentInfo: [
                AttachmentInfo(
                    id: attachmentID,
                    filename: "inline.png",
                    mimeType: "image/png",
                    size: inlineImageData.count,
                    contentId: "inline-migration",
                    inlineData: inlineImageData
                )
            ]
        )
        let expectedPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: attachmentID,
            ext: "png"
        )
        let expectedPreviewPath = AttachmentPaths.previewPath(
            messageId: message.id,
            attachmentId: attachmentID
        )
        defer {
            AttachmentPaths.deleteFile(at: legacyPath)
            AttachmentPaths.deleteFile(at: legacyPreviewPath)
            AttachmentPaths.deleteFile(at: expectedPath)
            AttachmentPaths.deleteFile(at: expectedPreviewPath)
        }

        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(attachment.localURL, expectedPath)
        XCTAssertEqual(attachment.previewURL, expectedPreviewPath)
        XCTAssertEqual(AttachmentPaths.loadData(from: attachment.localURL), inlineImageData)
        XCTAssertFalse(attachment.needsRedownload)
    }

    private func addConversationParticipant(person: Person, to conversation: Conversation) {
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
    }

    private func addMessageParticipant(person: Person, kind: ParticipantKind, to message: Message) {
        let participant = context.insertTestObject(MessageParticipant.self)
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }

    private func fetchMessage(id: String) throws -> Message? {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func makeMultipartAlternativeMessage(
        id: String,
        plainText: String,
        html: String,
        plainFirst: Bool
    ) -> GmailMessage {
        let plainPart = MessagePart(
            partId: "0.0",
            mimeType: "text/plain",
            filename: nil,
            headers: [
                MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8")
            ],
            body: MessageBody(
                size: plainText.count,
                data: plainText.data(using: .utf8)?.base64EncodedString(),
                attachmentId: nil
            ),
            parts: nil
        )
        let htmlPart = MessagePart(
            partId: "0.1",
            mimeType: "text/html",
            filename: nil,
            headers: [
                MessageHeader(name: "Content-Type", value: "text/html; charset=utf-8")
            ],
            body: MessageBody(
                size: html.count,
                data: html.data(using: .utf8)?.base64EncodedString(),
                attachmentId: nil
            ),
            parts: nil
        )

        return GmailMessage(
            id: id,
            threadId: "\(id)-thread",
            labelIds: ["INBOX"],
            snippet: "Reserve now",
            historyId: "12345",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: [
                    MessageHeader(name: "Subject", value: "Reservation offer"),
                    MessageHeader(name: "From", value: "Reservations <reservations@example.com>"),
                    MessageHeader(name: "To", value: "recipient@example.com")
                ],
                body: nil,
                parts: plainFirst ? [plainPart, htmlPart] : [htmlPart, plainPart]
            ),
            sizeEstimate: html.count + plainText.count
        )
    }
}

private final class InlineCIDPrefetchScheduleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [InlineCIDAttachmentPrefetchRequest] = []

    var requests: [InlineCIDAttachmentPrefetchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func record(_ request: InlineCIDAttachmentPrefetchRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }
}

private enum PersonDisplayInfoNotificationRecord {
    case unrelated
    case beforeSave
    case afterSave
}

private final class PersonDisplayInfoNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var didSave = false
    private var recordedNotifiedEmails = Set<String>()

    var notifiedEmails: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return recordedNotifiedEmails
    }

    func markSaved() {
        lock.lock()
        didSave = true
        lock.unlock()
    }

    func record(notification: Notification, senderEmail: String) -> PersonDisplayInfoNotificationRecord {
        let emails = PersonDisplayInfoChangeNotification.emails(from: notification)
        guard emails.contains(senderEmail) else {
            return .unrelated
        }

        lock.lock()
        defer { lock.unlock() }

        guard didSave else {
            return .beforeSave
        }

        recordedNotifiedEmails = emails
        return .afterSave
    }
}

private final class StubMessageProcessor: MessageProcessor, @unchecked Sendable {
    private let processedMessage: ProcessedMessage?

    init(processedMessage: ProcessedMessage?) {
        self.processedMessage = processedMessage
    }

    override func processGmailMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async -> ProcessedMessage? {
        processedMessage
    }
}

private final class HTMLSaveSpy {
    private let lock = NSLock()
    private var callCount = 0
    private var lastHTML: String?

    var recordedCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var recordedHTML: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastHTML
    }

    func save(_ html: String, messageId: String) -> URL? {
        lock.lock()
        callCount += 1
        lastHTML = html
        lock.unlock()
        return URL(fileURLWithPath: "/tmp/\(messageId).html")
    }
}
