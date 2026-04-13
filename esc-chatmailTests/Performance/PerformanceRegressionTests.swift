import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var contentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
        contentHandler = HTMLContentHandler()
    }

    override func tearDown() {
        contentHandler = nil
        context = nil
        stack = nil
        super.tearDown()
    }

    /// Protects the cold-ish inbox path: fetch active conversations, materialize row snapshots,
    /// and recompute the visible list model on a realistically large seeded dataset.
    func testPerformance_conversationListOpen_fetchSnapshotAndRefresh_largeInboxDataset() throws {
        let conversations = try PerformanceFixtureFactory.seedConversationList(in: context)
        let searchService = ConversationSearchService(debounceInterval: 60_000_000_000)
        let filterService = ConversationFilterService(contactsService: ContactsService())
        let viewModel = ConversationListViewModel(
            searchService: searchService,
            filterService: filterService
        )
        let options = makePerformanceOptions(iterationCount: 3)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            context.performAndWait { context.reset() }

            let request = Self.makeConversationFetchRequest()
            let fetched = try! context.fetch(request)
            let snapshots = fetched.map(ConversationSnapshot.init(from:))
            let newsletterSubset = filterService.filteredConversations(from: fetched, searchText: "weekly")

            MainActor.assumeIsolated {
                viewModel.refreshConversations(fetched)
                XCTAssertEqual(viewModel.filteredConversationItems.count, conversations.count)
            }

            XCTAssertEqual(fetched.count, conversations.count)
            XCTAssertEqual(snapshots.count, conversations.count)
            XCTAssertFalse(newsletterSubset.isEmpty)
        }
    }

    /// Protects the hot inbox-update path so small batches of changed conversations can update
    /// row snapshots and ordering without rebuilding the whole visible list model.
    func testPerformance_conversationListIncrementalRefresh_smallChangedSubset_largeInboxDataset() throws {
        let seededConversations = try PerformanceFixtureFactory.seedConversationList(
            in: context,
            conversationCount: 220
        )
        let request = Self.makeConversationFetchRequest()
        let fetched = try context.fetch(request)
        let changedObjectIDs = Array(seededConversations.prefix(8)).map(\.objectID)
        let searchService = ConversationSearchService(debounceInterval: 60_000_000_000)
        let filterService = ConversationFilterService(contactsService: ContactsService())
        let viewModel = ConversationListViewModel(
            searchService: searchService,
            filterService: filterService
        )
        let options = makePerformanceOptions(iterationCount: 5)

        viewModel.refreshConversations(fetched)
        XCTAssertEqual(viewModel.filteredConversationItems.count, seededConversations.count)

        var iteration = 0
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            iteration += 1
            let changedConversations = changedObjectIDs.compactMap { objectID in
                try? context.existingObject(with: objectID) as? Conversation
            }

            for (offset, conversation) in changedConversations.enumerated() {
                conversation.snippet = "Incremental update \(iteration)-\(offset)"
                conversation.inboxUnreadCount = Int32(iteration + offset)
            }

            changedConversations.first?.lastMessageDate = Date(
                timeIntervalSince1970: 10_000 + Double(iteration)
            )

            MainActor.assumeIsolated {
                viewModel.applyConversationChanges(updatedConversations: changedConversations)
                XCTAssertEqual(viewModel.filteredConversationItems.count, seededConversations.count)
            }
        }
    }

    /// Protects row hydration at scroll-like scale by resolving participant display models for a
    /// large window of conversations without involving Contacts or avatar I/O.
    func testPerformance_conversationRowParticipantHydration_scrollWindow() throws {
        let conversations = try PerformanceFixtureFactory.seedConversationList(
            in: context,
            conversationCount: 220
        )
        let conversationObjectIDs = Array(conversations.prefix(120)).map(\.objectID)
        let contactMap = makeContactMap(from: conversations)
        let loader = ParticipantLoader(
            contactsResolver: PerformanceMockContactsResolver(contactMap: contactMap),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] }
        )
        let options = makePerformanceOptions(iterationCount: 3)

        measureAsync(
            metrics: [XCTClockMetric(), XCTCPUMetric()],
            options: options,
            timeout: 30.0
        ) {
            var loadedDisplayNames: [String] = []

            for objectID in conversationObjectIDs {
                let info = await loader.loadParticipants(
                    from: objectID,
                    in: self.context,
                    currentUserEmail: PerformanceFixtureFactory.currentUserEmail,
                    maxParticipants: 4,
                    includePhotos: false
                )
                loadedDisplayNames.append(info.formattedDisplayName)
            }

            XCTAssertEqual(loadedDisplayNames.count, conversationObjectIDs.count)
            XCTAssertFalse(loadedDisplayNames.contains(where: \.isEmpty))
        }
    }

    /// Protects the chat-thread open path by fetching a long thread, deriving sender grouping keys,
    /// and preparing visible bubble content for the most recent messages.
    func testPerformance_chatThreadOpen_fetchGroupingAndVisibleBubbleLoading_longConversation() throws {
        let seededThread = try PerformanceFixtureFactory.seedLongThread(
            in: context,
            htmlContentHandler: contentHandler
        )
        defer {
            PerformanceFixtureFactory.cleanupHTMLArtifacts(
                for: seededThread.htmlMessageIDs,
                using: contentHandler
            )
        }

        let recentMessageIDs = Array(seededThread.messages.suffix(30)).map(\.id)
        let contactsResolver = PerformanceMockContactsResolver(contactMap: makeContactMap(from: seededThread.messages))
        let participantLoader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] }
        )
        let bubbleLoader = MessageBubbleLoader(
            contactsResolver: contactsResolver,
            htmlContentRecoveryService: EmptyHTMLContentRecoverer()
        )
        let conversationID = seededThread.conversation.objectID
        let options = makePerformanceOptions(iterationCount: 3)

        measureAsync(
            metrics: [XCTClockMetric(), XCTCPUMetric()],
            options: options,
            timeout: 45.0
        ) {
            for messageID in recentMessageIDs {
                await ProcessedTextCache.shared.invalidate(messageId: messageID)
            }

            self.context.performAndWait { self.context.reset() }

            let conversation = try XCTUnwrap(
                self.context.existingObject(with: conversationID) as? Conversation
            )
            let fetchedMessages = try self.context.fetch(Self.makeThreadFetchRequest(for: conversation))
            let uniqueSenderEmails = Array(Set(fetchedMessages.compactMap(\.senderEmailValue)))
            let groupingKeys = await participantLoader.senderGroupingKeys(for: uniqueSenderEmails)

            XCTAssertFalse(groupingKeys.isEmpty)
            XCTAssertEqual(fetchedMessages.count, seededThread.messages.count)

            for message in fetchedMessages.suffix(30) {
                let request = Self.makeBubbleContentRequest(from: message)
                let result = await bubbleLoader.loadContent(from: request)

                XCTAssertTrue(
                    result.fullTextContent != nil || result.hasRichHTMLContent || !message.hasHTMLSource,
                    "Expected visible content or rich HTML marker for message \(message.id)"
                )
            }
        }
    }

    /// Protects the common HTML email path so medium-sized messages do not regress on preview and
    /// full-message rendering after sanitizer or wrapper changes.
    func testPerformance_htmlContentLoader_mediumHTML_previewAndOriginalPaths() {
        let loader = makeHTMLLoader()
        let messageId = "perf-medium-\(UUID().uuidString)"
        let html = PerformanceFixtureFactory.mediumHTMLMessage()
        _ = contentHandler.saveHTML(html, for: messageId)
        defer { contentHandler.deleteHTML(for: messageId) }

        let options = makePerformanceOptions(iterationCount: 3)
        measureAsync(
            metrics: [XCTClockMetric(), XCTCPUMetric()],
            options: options,
            timeout: 30.0
        ) {
            loader.invalidate(messageId: messageId)

            let preview = await loader.loadContent(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: nil,
                senderEmail: "updates@example.com",
                subject: "Project Update",
                isDarkMode: false,
                cleanupMode: .none,
                displayPurpose: .preview
            )
            let original = await loader.loadContent(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: nil,
                senderEmail: "updates@example.com",
                subject: "Project Update",
                isDarkMode: false,
                cleanupMode: .none,
                displayPurpose: .original
            )

            XCTAssertNotNil(preview.html)
            XCTAssertEqual(preview.source, .messageId)
            XCTAssertEqual(original.presentation, .html)
            XCTAssertNotNil(original.html)
        }
    }

    /// Protects the heaviest HTML loader path with both time and memory metrics for large
    /// newsletter-style messages that contain many sections and images.
    func testPerformance_htmlContentLoader_largeNewsletter_previewAndOriginalPaths() {
        let loader = makeHTMLLoader()
        let messageId = "perf-newsletter-\(UUID().uuidString)"
        let html = PerformanceFixtureFactory.largeNewsletterHTML()
        _ = contentHandler.saveHTML(html, for: messageId)
        defer { contentHandler.deleteHTML(for: messageId) }

        let options = makePerformanceOptions(iterationCount: 3)
        measureAsync(
            metrics: [XCTClockMetric(), XCTMemoryMetric()],
            options: options,
            timeout: 45.0
        ) {
            loader.invalidate(messageId: messageId)

            let preview = await loader.loadContent(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: nil,
                senderEmail: "newsletter@example.com",
                subject: "Weekly Product Dispatch",
                isDarkMode: false,
                cleanupMode: .none,
                displayPurpose: .preview
            )
            let original = await loader.loadContent(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: nil,
                senderEmail: "newsletter@example.com",
                subject: "Weekly Product Dispatch",
                isDarkMode: false,
                cleanupMode: .none,
                displayPurpose: .original
            )

            XCTAssertNotNil(preview.html)
            XCTAssertEqual(original.presentation, .html)
            XCTAssertNotNil(original.html)
        }
    }

    /// Protects the plain-text fallback path used when HTML is missing or intentionally bypassed.
    func testPerformance_htmlContentLoader_plainTextFallback_largeBody() {
        let loader = makeHTMLLoader()
        let messageId = "perf-plain-\(UUID().uuidString)"
        let bodyText = PerformanceFixtureFactory.plainTextFallbackBody()
        let options = makePerformanceOptions(iterationCount: 3)

        measureAsync(
            metrics: [XCTClockMetric(), XCTCPUMetric()],
            options: options,
            timeout: 20.0
        ) {
            loader.invalidate(messageId: messageId)

            let result = await loader.loadContent(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: bodyText,
                senderEmail: "plain@example.com",
                subject: "Plain Text Fallback",
                isDarkMode: false,
                cleanupMode: .none,
                displayPurpose: .preview
            )

            XCTAssertEqual(result.source, .plainTextFallback)
            XCTAssertNotNil(result.html)
        }
    }

    /// Guards against repeated large-message opens accumulating HTML cache variants or stale
    /// artifacts within the scope of a single test run.
    func testMemory_htmlContentLoader_repeatedLargeNewsletterOpen_keepsCacheBounded() {
        let loader = makeHTMLLoader()
        let messageId = "perf-memory-\(UUID().uuidString)"
        let html = PerformanceFixtureFactory.largeNewsletterHTML(sectionCount: 28, repeatedParagraphCount: 4)
        _ = contentHandler.saveHTML(html, for: messageId)
        defer { contentHandler.deleteHTML(for: messageId) }

        waitForAsync(timeout: 30.0) {
            for _ in 0..<10 {
                _ = await loader.loadContent(
                    messageId: messageId,
                    bodyStorageURI: nil,
                    bodyText: nil,
                    senderEmail: "newsletter@example.com",
                    subject: "Weekly Product Dispatch",
                    isDarkMode: false,
                    cleanupMode: .none,
                    displayPurpose: .preview
                )
                _ = await loader.loadContent(
                    messageId: messageId,
                    bodyStorageURI: nil,
                    bodyText: nil,
                    senderEmail: "newsletter@example.com",
                    subject: "Weekly Product Dispatch",
                    isDarkMode: false,
                    cleanupMode: .none,
                    displayPurpose: .original
                )
            }
        }

        XCTAssertEqual(loader.debugCachedVariantCount(for: messageId), 2)
        XCTAssertEqual(loader.debugTotalCachedVariantCount(), 2)

        loader.invalidate(messageId: messageId)

        XCTAssertEqual(loader.debugCachedVariantCount(for: messageId), 0)
        XCTAssertEqual(loader.debugTotalCachedVariantCount(), 0)
    }

    private func makeHTMLLoader() -> HTMLContentLoader {
        HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared,
            remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback(
                requestExecutor: { _ in throw URLError(.unsupportedURL) }
            )
        )
    }

    private func makeContactMap(from conversations: [Conversation]) -> [String: ContactMatch] {
        let participants = conversations
            .flatMap { Array($0.participants ?? []) }
            .compactMap(\.person)

        return makeContactMap(
            from: participants.map { person in
                (person.email, person.displayName ?? EmailNormalizer.formatAsDisplayName(email: person.email))
            }
        )
    }

    private func makeContactMap(from messages: [Message]) -> [String: ContactMatch] {
        let senderPairs = messages.compactMap { message -> (String, String)? in
            guard let email = message.senderEmailValue else { return nil }
            let name = message.senderNameValue ?? EmailNormalizer.formatAsDisplayName(email: email)
            return (email, name)
        }

        return makeContactMap(from: senderPairs)
    }

    private func makeContactMap(from entries: [(String, String)]) -> [String: ContactMatch] {
        var contactMap: [String: ContactMatch] = [:]

        for (email, name) in entries {
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard normalizedEmail != EmailNormalizer.normalize(PerformanceFixtureFactory.currentUserEmail) else {
                continue
            }

            if contactMap[normalizedEmail] == nil {
                contactMap[normalizedEmail] = ContactMatch(
                    displayName: name,
                    email: email,
                    imageData: nil,
                    contactIdentifier: "contact-\(normalizedEmail)"
                )
            }
        }

        return contactMap
    }

    private func makePerformanceOptions(iterationCount: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterationCount
        return options
    }

    private static func makeConversationFetchRequest() -> NSFetchRequest<Conversation> {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = NSPredicate(format: "archivedAt == nil")
        request.fetchBatchSize = 20
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        return request
    }

    private static func makeThreadFetchRequest(for conversation: Conversation) -> NSFetchRequest<Message> {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
        request.predicate = NSPredicate(
            format: "conversation == %@ AND NOT (ANY labels.id == %@)",
            conversation,
            "DRAFT"
        )
        request.fetchBatchSize = CoreDataConfig.fetchBatchSize
        request.relationshipKeyPathsForPrefetching = [
            "participants",
            "participants.person",
            "attachments",
            "labels"
        ]
        return request
    }

    private static func makeBubbleContentRequest(from message: Message) -> MessageBubbleContentRequest {
        MessageBubbleContentRequest(
            messageID: message.id,
            bodyText: message.bodyTextValue,
            bodyStorageURI: message.bodyStorageURI,
            snippet: message.snippet,
            hasHTMLSource: message.hasHTMLSource,
            hasAttachments: message.hasAttachments,
            isFromMe: message.isFromMe,
            isForwardedEmail: message.isForwardedEmail,
            effectiveSenderEmail: message.senderEmailValue
        )
    }
}

private final class PerformanceMockContactsResolver: ContactsResolving, @unchecked Sendable {
    private let contactMap: [String: ContactMatch]

    init(contactMap: [String: ContactMatch]) {
        self.contactMap = contactMap
    }

    func ensureAuthorization() async throws {}

    func lookup(email: String) async -> ContactMatch? {
        let normalizedEmail = EmailNormalizer.normalize(email)
        return contactMap[normalizedEmail] ?? contactMap[email]
    }

    func prewarm(emails: [String]) async {}
}

private struct EmptyHTMLContentRecoverer: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? { nil }
}
