import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationRollupUpdaterTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var updater: ConversationRollupUpdater!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        updater = ConversationRollupUpdater()
    }

    override func tearDown() {
        updater = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testUpdateRollups_clearsLatestInboxDateWhenNoInboxMessages() throws {
        let staleInboxDate = Date(timeIntervalSince1970: 100)
        let sentDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Stale inbox preview")
            .withLastMessageDate(staleInboxDate)
            .hasInboxMessages(true)
            .visible()
            .build(in: context)
        conversation.latestInboxDate = staleInboxDate

        let sentLabel = LabelBuilder().sent().build(in: context)
        let sentMessage = MessageBuilder()
            .withId("rollup-sent-only")
            .withDate(sentDate)
            .withSnippet("Latest sent preview")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        sentMessage.addToLabels(sentLabel)

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
        XCTAssertEqual(conversation.lastMessageDate, sentDate)
        XCTAssertEqual(conversation.snippet, "Latest sent preview")
    }

    func testUpdateRollups_clearsVisibleMetadataWhenNoVisibleMessagesRemain() throws {
        let staleDate = Date(timeIntervalSince1970: 100)
        let draftDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Stale visible preview")
            .withLastMessageDate(staleDate)
            .visible()
            .build(in: context)
        conversation.latestInboxDate = staleDate

        let draftLabel = LabelBuilder().draft().build(in: context)
        let draftMessage = MessageBuilder()
            .withId("rollup-draft-only")
            .withDate(draftDate)
            .withSnippet("Draft preview should not drive rollup")
            .inConversation(conversation)
            .build(in: context)
        draftMessage.addToLabels(draftLabel)

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertFalse(conversation.hasInbox)
        XCTAssertEqual(conversation.inboxUnreadCount, 0)
        XCTAssertNil(conversation.latestInboxDate)
        XCTAssertNil(conversation.lastMessageDate)
        XCTAssertNil(conversation.snippet)
    }

    func testUpdateRollups_keepsActiveConversationVisibleWhenLatestMessageIsOutgoing() throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let sentDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Old archived incoming")
            .withLastMessageDate(oldDate)
            .visible()
            .hasInboxMessages(false)
            .build(in: context)

        MessageBuilder()
            .withId("old-received-message")
            .withDate(oldDate)
            .withSnippet("Old archived incoming")
            .inConversation(conversation)
            .build(in: context)

        let sentLabel = LabelBuilder().sent().build(in: context)
        let sentMessage = MessageBuilder()
            .withId("latest-sent-message")
            .withDate(sentDate)
            .withSnippet("Latest outgoing")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        sentMessage.addToLabels(sentLabel)

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertFalse(conversation.hasInbox)
        XCTAssertNil(conversation.archivedAt)
        XCTAssertFalse(conversation.hidden)
        XCTAssertEqual(conversation.lastMessageDate, sentDate)
        XCTAssertEqual(conversation.snippet, "Latest outgoing")
    }

    func testUpdateRollups_newsletterWithBlankSubjectFallsBackToStoredSnippet() throws {
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)

        let message = MessageBuilder()
            .withId("newsletter-blank-subject")
            .withDate(messageDate)
            .withSnippet("Raw newsletter preview")
            .asNewsletter()
            .inConversation(conversation)
            .build(in: context)
        message.subject = " \n\t "
        message.cleanedSnippet = "Clean newsletter preview"

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.lastMessageDate, messageDate)
        XCTAssertEqual(conversation.snippet, "Clean newsletter preview")
    }

    func testUpdateRollups_usesChatPreviewTextWhenListSnippetsAreMissing() throws {
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)

        let message = MessageBuilder()
            .withId("rollup-chat-preview-only")
            .withDate(messageDate)
            .withSubject("Subject fallback")
            .withSnippet(" \n\t ")
            .inConversation(conversation)
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = "Chat preview line one.\n\nLine two."

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.lastMessageDate, messageDate)
        XCTAssertEqual(conversation.snippet, "Chat preview line one. Line two.")
    }

    func testUpdateRollups_fallsBackToPreviousVisiblePreviewWhenLatestVisiblePreviewIsMissing() throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let latestDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Existing row preview")
            .withLastMessageDate(oldDate)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("older-visible-preview")
            .withDate(oldDate)
            .withSnippet("Existing row preview")
            .inConversation(conversation)
            .build(in: context)
        let message = MessageBuilder()
            .withId("latest-visible-missing-preview")
            .withDate(latestDate)
            .withSnippet(" \n\t ")
            .inConversation(conversation)
            .build(in: context)
        message.subject = nil
        message.cleanedSnippet = nil

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.lastMessageDate, latestDate)
        XCTAssertEqual(conversation.snippet, "Existing row preview")
    }

    func testUpdateRollupsClearsStaleSnippetWhenNoVisiblePreviewExists() throws {
        let messageDate = Date(timeIntervalSince1970: 200)

        let conversation = ConversationBuilder()
            .withSnippet("Stale row preview")
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)
        let message = MessageBuilder()
            .withId("visible-missing-preview")
            .withDate(messageDate)
            .withSnippet(" \n\t ")
            .inConversation(conversation)
            .build(in: context)
        message.subject = nil
        message.cleanedSnippet = nil

        try context.save()

        updater.updateRollups(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.lastMessageDate, messageDate)
        XCTAssertNil(conversation.snippet)
    }

    func testRepairMissingConversationPreviewsRestoresStoredMessagePreview() async throws {
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)

        let message = MessageBuilder()
            .withId("repair-missing-conversation-preview")
            .withDate(messageDate)
            .withSnippet("Raw repair preview")
            .inConversation(conversation)
            .build(in: context)
        message.cleanedSnippet = "Clean repair preview"

        try context.save()

        let result = await updater.repairMissingConversationPreviews(in: context)

        XCTAssertEqual(result.repairedCount, 1)
        XCTAssertTrue(result.didDrain)
        XCTAssertEqual(conversation.snippet, "Clean repair preview")
    }

    func testRepairMissingConversationPreviewsRestoresChatPreviewOnlyMessagePreview() async throws {
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)

        let message = MessageBuilder()
            .withId("repair-chat-preview-only")
            .withDate(messageDate)
            .withSubject("Subject fallback")
            .withSnippet(" \n\t ")
            .inConversation(conversation)
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = "Chat repair preview.\n\nSecond line."

        try context.save()

        let result = await updater.repairMissingConversationPreviews(in: context)

        XCTAssertEqual(result.repairedCount, 1)
        XCTAssertTrue(result.didDrain)
        XCTAssertEqual(conversation.snippet, "Chat repair preview. Second line.")
    }

    func testRepairMissingConversationPreviewsRestoresSubjectOnlyMessagePreview() async throws {
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)

        let message = MessageBuilder()
            .withId("repair-subject-only")
            .withDate(messageDate)
            .withSubject("Subject repair preview")
            .withSnippet(" \n\t ")
            .inConversation(conversation)
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = " \n\t "

        try context.save()

        let result = await updater.repairMissingConversationPreviews(in: context)

        XCTAssertEqual(result.repairedCount, 1)
        XCTAssertTrue(result.didDrain)
        XCTAssertEqual(conversation.snippet, "Subject repair preview")
    }

    func testRepairMissingConversationPreviewsRestoresWhitespaceOnlyConversationPreviewInSQLiteStore() async throws {
        let sqliteStack = TestCoreDataStack(storeKind: .sqlite)
        let sqliteContext = sqliteStack.viewContext
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withSnippet(" \n\t ")
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: sqliteContext)

        let message = MessageBuilder()
            .withId("repair-whitespace-conversation-preview")
            .withDate(messageDate)
            .withSnippet("Raw repair preview")
            .inConversation(conversation)
            .build(in: sqliteContext)
        message.cleanedSnippet = "Clean repair preview"

        try sqliteStack.saveViewContext()

        let result = await updater.repairMissingConversationPreviews(in: sqliteContext)

        XCTAssertEqual(result.repairedCount, 1)
        XCTAssertTrue(result.didDrain)
        XCTAssertEqual(conversation.snippet, "Clean repair preview")
    }

    func testRepairMissingConversationPreviewsScansPastUnrepairableNewerRows() async throws {
        for index in 0..<3 {
            ConversationBuilder()
                .withLastMessageDate(Date(timeIntervalSince1970: 300 + TimeInterval(index)))
                .visible()
                .build(in: context)
        }

        let repairableConversation = ConversationBuilder()
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("repair-older-conversation-preview")
            .withDate(Date(timeIntervalSince1970: 100))
            .withSnippet("Older repair preview")
            .inConversation(repairableConversation)
            .build(in: context)

        try context.save()

        let result = await updater.repairMissingConversationPreviews(in: context, limit: 1)

        XCTAssertEqual(result.repairedCount, 1)
        XCTAssertFalse(result.didDrain)
        XCTAssertEqual(repairableConversation.snippet, "Older repair preview")
    }

    func testArchiveMessagelessConversationsArchivesStaleConversationShell() async throws {
        // No createdAt: a legacy row from before the attribute existed, shielded
        // only by the lastMessageDate cutoff.
        let staleDate = Date(timeIntervalSince1970: 200)
        let shell = ConversationBuilder()
            .withLastMessageDate(staleDate)
            .visible()
            .build(in: context)

        try context.save()

        let archivedCount = await updater.archiveMessagelessConversations(
            in: context,
            olderThan: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(archivedCount, 1)
        XCTAssertNotNil(shell.archivedAt)
        XCTAssertTrue(shell.hidden)
        XCTAssertNil(shell.lastMessageDate)
        XCTAssertNil(shell.snippet)
        XCTAssertFalse(shell.hasInbox)
    }

    func testArchiveMessagelessConversationsArchivesShellCreatedBeforeCutoff() async throws {
        let staleDate = Date(timeIntervalSince1970: 200)
        let shell = ConversationBuilder()
            .withLastMessageDate(staleDate)
            .withCreatedAt(Date(timeIntervalSince1970: 500))
            .visible()
            .build(in: context)

        try context.save()

        let archivedCount = await updater.archiveMessagelessConversations(
            in: context,
            olderThan: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(archivedCount, 1)
        XCTAssertNotNil(shell.archivedAt)
        XCTAssertTrue(shell.hidden)
    }

    func testArchiveMessagelessConversationsSkipsShellsWithinGracePeriod() async throws {
        let recentDate = Date(timeIntervalSince1970: 2_000)
        let shell = ConversationBuilder()
            .withLastMessageDate(recentDate)
            .visible()
            .build(in: context)

        try context.save()

        let archivedCount = await updater.archiveMessagelessConversations(
            in: context,
            olderThan: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(archivedCount, 0)
        XCTAssertNil(shell.archivedAt)
        XCTAssertEqual(shell.lastMessageDate, recentDate)
    }

    func testArchiveMessagelessConversationsSkipsRecentlyCreatedShellWithHistoricalDate() async throws {
        // A sync-created shell carries the message's historical internalDate as
        // lastMessageDate, so a shell saved moments ago can look arbitrarily stale.
        // Its fresh createdAt must shield it while the message is still in flight.
        let historicalDate = Date(timeIntervalSince1970: 200)
        let shell = ConversationBuilder()
            .withLastMessageDate(historicalDate)
            .withCreatedAt(Date(timeIntervalSince1970: 2_000))
            .visible()
            .build(in: context)

        try context.save()

        let archivedCount = await updater.archiveMessagelessConversations(
            in: context,
            olderThan: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(archivedCount, 0)
        XCTAssertNil(shell.archivedAt)
        XCTAssertFalse(shell.hidden)
        XCTAssertEqual(shell.lastMessageDate, historicalDate)
    }

    func testArchiveMessagelessConversationsSkipsConversationsWithMessages() async throws {
        let messageDate = Date(timeIntervalSince1970: 200)
        let conversation = ConversationBuilder()
            .withLastMessageDate(messageDate)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("messageless-sweep-has-message")
            .withDate(messageDate)
            .withSnippet("Existing preview")
            .inConversation(conversation)
            .build(in: context)

        try context.save()

        let archivedCount = await updater.archiveMessagelessConversations(
            in: context,
            olderThan: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(archivedCount, 0)
        XCTAssertNil(conversation.archivedAt)
        XCTAssertEqual(conversation.lastMessageDate, messageDate)
    }

    func testUpdateDisplayNameOnly_noRealNameUsesEmailAddress() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "john.smith@example.com")
    }

    func testUpdateDisplayNameOnly_usesExplicitHeaderDisplayName() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        MessageBuilder()
            .withSender(email: "john.smith@example.com", name: "John Smith")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "John Smith")
    }

    func testUpdateDisplayNameOnly_usesExplicitBrandNameMatchingEmailLocalPart() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .build(in: context)
        addConversationParticipant(
            email: "a16z@substack.com",
            displayName: "a16z",
            to: conversation
        )
        _ = MessageBuilder()
            .withSender(email: "a16z@substack.com", name: "a16z")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "a16z")
    }

    func testUpdateDisplayNameOnly_usesStoredNameWhenHeaderIsPlainRawLocalPart() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .build(in: context)
        addConversationParticipant(
            email: "john@example.com",
            displayName: "John Appleseed",
            to: conversation
        )
        _ = MessageBuilder()
            .withSender(email: "john@example.com", name: "john")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "John Appleseed")
    }

    func testUpdateDisplayNameOnly_upgradesLegacyAddressDerivedNameToStoredRealName() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "Address Book John",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Address Book John")
    }

    func testUpdateDisplayNameOnly_groupOmitsAddressDerivedNamesAndShowsCount() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John & Sarah")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        addConversationParticipant(
            email: "sarah@example.com",
            displayName: "Sarah Connor",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Sarah Connor +1")
    }

    func testUpdateDisplayNameOnly_groupWithNoRealNamesKeepsCleanStoredTitle() throws {
        // Participant names here all resolve as address-derived (they mirror
        // the local parts), leaving zero real names. The stored "John & Jane"
        // is still a clean human-readable title — keeping it beats downgrading
        // the row to joined addresses, which is what stranded real groups on
        // "a@x.com, b@y.com" rows.
        let conversation = ConversationBuilder()
            .withDisplayName("John & Jane")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        addConversationParticipant(
            email: "jane.doe@example.com",
            displayName: "Jane Doe",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "John & Jane")
    }

    func testUpdateDisplayNameOnly_groupWithAddressStoredTitleRejoinsAddresses() throws {
        // A stored title that is literally addresses still normalizes to the
        // canonical joined-address fallback.
        let conversation = ConversationBuilder()
            .withDisplayName("john.smith@example.com, jane.doe@example.com")
            .build(in: context)
        addConversationParticipant(
            email: "john.smith@example.com",
            displayName: "John Smith",
            to: conversation
        )
        addConversationParticipant(
            email: "jane.doe@example.com",
            displayName: "Jane Doe",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "jane.doe@example.com, john.smith@example.com")
    }

    func testUpdateDisplayNameOnly_listKeepsStoredPhraseTitle() throws {
        // The List-Id display phrase seeded at creation must not be replaced
        // by sender-derived names — list senders vary per message. This
        // phrase's label key passes the opaqueness profile, so the title
        // survives only through its internal whitespace (the titleIsBareToken
        // gate) — keep it multi-word when editing.
        let storedTitle = "Formula 1 2024 Round 12 Highlights"
        let conversation = ConversationBuilder()
            .asList()
            .withListId("formula1-2024-round12-highlights.community.example")
            .withDisplayName(storedTitle)
            .build(in: context)
        addConversationParticipant(
            email: "newsletter@example.com",
            displayName: "Formula One Editors",
            to: conversation
        )
        MessageBuilder()
            .withId("digit-heavy-human-list-title")
            .withSender(email: "newsletter@example.com", name: "Formula One Editors")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, storedTitle)
    }

    func testUpdateDisplayNameOnly_listKeepsBareListIdFallbackTitle() throws {
        // Without any message evidence of a single sender, the stable List-Id
        // placeholder stays.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("thebrowser.substack.com")
            .withDisplayName("thebrowser.substack.com")
            .build(in: context)
        addConversationParticipant(
            email: "newsletter@thebrowser.com",
            displayName: "The Browser Editors",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "thebrowser.substack.com")
    }

    func testUpdateDisplayNameOnly_listBareListIdTitleUpgradesToSingleSenderName() throws {
        // A title equal to the raw List-Id is the bare-header creation
        // fallback, not a real phrase. Once the list has a single distinct
        // sender, the sender's From name replaces the machine identifier.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("tbpn.mail.beehiiv.com")
            .withDisplayName("tbpn.mail.beehiiv.com")
            .build(in: context)
        addConversationParticipant(
            email: "tbpn@mail.beehiiv.com",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("list-single-sender-1")
            .withSender(email: "tbpn@mail.beehiiv.com", name: "TBPN")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "TBPN")
    }

    func testUpdateDisplayNameOnly_listMailchimpIdentifierPhraseUpgradesToSingleSenderName() throws {
        let conversation = ConversationBuilder()
            .asList()
            .withListId("d90192af1525703adec3d3919.657565.list-id.mcsv.net")
            .withDisplayName("d90192af1525703adec3d3919mc list")
            .build(in: context)
        addConversationParticipant(
            email: "info@bedfordplayhouse.org",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("mailchimp-list-single-sender")
            .withSender(email: "info@bedfordplayhouse.org", name: "Bedford Playhouse")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Bedford Playhouse")
    }

    func testUpdateDisplayNameOnly_listBrevoIdentifierPhraseUpgradesToSingleSenderName() throws {
        // Revert-check: the bare-token rule in
        // ParsedListId.isIdentifierDerivedDisplayTitle — a stored Brevo token
        // title must read as identifier-derived so the single-sender upgrade
        // replaces it, exactly like the Mailchimp phrase above.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("odi2oti3ny04mtyyni0z.list-id.mailin.fr")
            .withDisplayName("ODI2OTI3Ny04MTYyNi0z")
            .build(in: context)
        addConversationParticipant(
            email: "support@subdial.com",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("brevo-list-single-sender")
            .withSender(email: "support@subdial.com", name: "Subdial")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Subdial")
    }

    func testUpdateDisplayNameOnly_listBrevoCustomDomainBase64TitleUpgradesToSingleSenderName() throws {
        // Revert-check: ParsedListId.isBase64EncodedNumericIdentifier — a
        // stored custom-domain Brevo token title (base64 of
        // "10226015-235877-0", too digit-sparse for the literal-digit
        // profiles and outside the provider suffix allowlist) must read as
        // identifier-derived so the single-sender upgrade replaces it with
        // the newsletter's From name.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("mtaymjywmtutmjm1odc3lta=.list-id.email-newsletters.timeout.com")
            .withDisplayName("MTAyMjYwMTUtMjM1ODc3LTA=")
            .build(in: context)
        addConversationParticipant(
            email: "news@email-newsletters.timeout.com",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("brevo-custom-domain-list-single-sender")
            .withSender(email: "news@email-newsletters.timeout.com", name: "Time Out")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Time Out")
    }

    func testRepairIdentifierDerivedListConversationTitles_upgradesMachineTitleAndKeepsHumanTitle() async throws {
        // Revert-check:
        // ConversationRollupUpdater.repairIdentifierDerivedListConversationTitles —
        // the per-launch list pass must heal a title stored under an older
        // ParsedListId heuristic with no migration flag involved, and its
        // candidate filter must leave human-titled list conversations alone.
        let machine = ConversationBuilder()
            .asList()
            .withListId("mtaymjywmtutmjm1odc3lta=.list-id.email-newsletters.timeout.com")
            .withDisplayName("MTAyMjYwMTUtMjM1ODc3LTA=")
            .build(in: context)
        addConversationParticipant(
            email: "news@email-newsletters.timeout.com",
            displayName: nil,
            to: machine
        )
        MessageBuilder()
            .withId("list-title-repair-machine")
            .withSender(email: "news@email-newsletters.timeout.com", name: "Time Out")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(machine)
            .build(in: context)

        let human = ConversationBuilder()
            .asList()
            .withListId("friends-of-bob.example.com")
            .withDisplayName("Friends of Bob")
            .build(in: context)
        addConversationParticipant(
            email: "bob@example.com",
            displayName: nil,
            to: human
        )
        MessageBuilder()
            .withId("list-title-repair-human")
            .withSender(email: "bob@example.com", name: "Bob")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(human)
            .build(in: context)
        try context.save()

        let repairedCount = await updater.repairIdentifierDerivedListConversationTitles(
            in: context,
            myEmail: "me@example.com"
        )

        XCTAssertEqual(repairedCount, 1)
        XCTAssertEqual(machine.displayName, "Time Out")
        XCTAssertEqual(human.displayName, "Friends of Bob")
    }

    func testUpdateDisplayNameOnly_listMailchimpIdentifierPhraseDoesNotChurnAcrossMultipleSenders() throws {
        let machineTitle = "d90192af1525703adec3d3919mc list"
        let conversation = ConversationBuilder()
            .asList()
            .withListId("d90192af1525703adec3d3919.657565.list-id.mcsv.net")
            .withDisplayName(machineTitle)
            .build(in: context)
        MessageBuilder()
            .withId("mailchimp-list-sender-1")
            .withSender(email: "first@example.com", name: "First Sender")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("mailchimp-list-sender-2")
            .withSender(email: "second@example.com", name: "Second Sender")
            .withDate(Date(timeIntervalSince1970: 200))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, machineTitle)
    }

    func testUpdateDisplayNameOnly_listBareListIdTitleIgnoresOwnRepliesWhenCountingSenders() throws {
        let conversation = ConversationBuilder()
            .asList()
            .withListId("tbpn.mail.beehiiv.com")
            .withDisplayName("tbpn.mail.beehiiv.com")
            .build(in: context)
        addConversationParticipant(
            email: "tbpn@mail.beehiiv.com",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("list-single-sender-newsletter")
            .withSender(email: "tbpn@mail.beehiiv.com", name: "TBPN")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("list-single-sender-own-reply")
            .withSender(email: "me@example.com")
            .withDate(Date(timeIntervalSince1970: 200))
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "TBPN")
    }

    func testUpdateDisplayNameOnly_listBareListIdTitleWithMultipleSendersKeepsPlaceholder() throws {
        // Discussion lists rotate senders; the stable List-Id placeholder
        // beats a title that would churn with every post.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("misc.example.groups.io")
            .withDisplayName("misc.example.groups.io")
            .build(in: context)
        addConversationParticipant(
            email: "alice@example.com",
            displayName: "Alice Adams",
            to: conversation
        )
        MessageBuilder()
            .withId("list-multi-sender-1")
            .withSender(email: "alice@example.com", name: "Alice Adams")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("list-multi-sender-2")
            .withSender(email: "bob@example.com", name: "Bob Brown")
            .withDate(Date(timeIntervalSince1970: 200))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "misc.example.groups.io")
    }

    func testUpdateDisplayNameOnly_latestFromHeaderNameWinsOverOlderMultiWordName() throws {
        // A sender that rebrands ("Technology Brothers" → "TBPN") must show
        // the current From name; the old multi-word name must not ratchet.
        let conversation = ConversationBuilder()
            .withDisplayName("Technology Brothers")
            .build(in: context)
        addConversationParticipant(
            email: "tbpn@mail.beehiiv.com",
            displayName: "Technology Brothers",
            to: conversation
        )
        MessageBuilder()
            .withId("rebrand-older")
            .withSender(email: "tbpn@mail.beehiiv.com", name: "Technology Brothers")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("rebrand-newer")
            .withSender(email: "tbpn@mail.beehiiv.com", name: "TBPN")
            .withDate(Date(timeIntervalSince1970: 200))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "TBPN")
    }

    func testUpdateDisplayNameOnly_olderFullerVariantStillUpgradesShortLatestName() throws {
        // The recency rule must not regress the "Katie" → "Katie Thau"
        // upgrade: an older, fuller variant of the same name still wins.
        let conversation = ConversationBuilder()
            .withDisplayName("Katie")
            .build(in: context)
        addConversationParticipant(
            email: "katie@example.com",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("fuller-older")
            .withSender(email: "katie@example.com", name: "Katie Thau")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("fuller-newer")
            .withSender(email: "katie@example.com", name: "Katie")
            .withDate(Date(timeIntervalSince1970: 200))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Katie Thau")
    }

    func testUpdateDisplayNameOnly_equalDateHeaderNamesTieBreakOnMessageId() throws {
        // Two distinct From names with identical internalDates: the higher
        // message id counts as newest, keeping the winner deterministic.
        let conversation = ConversationBuilder()
            .withDisplayName("Tie")
            .build(in: context)
        addConversationParticipant(
            email: "tie@example.com",
            displayName: nil,
            to: conversation
        )
        MessageBuilder()
            .withId("tie-a")
            .withSender(email: "tie@example.com", name: "Alpha")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        MessageBuilder()
            .withId("tie-b")
            .withSender(email: "tie@example.com", name: "Beta")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "Beta")
    }

    func testUpdateDisplayNameOnly_listWithoutTitleComputesSenderDerivedName() throws {
        // No List-Id phrase was available at creation: the normal participant
        // computation must fill the title in.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("thebrowser.substack.com")
            .build(in: context)
        addConversationParticipant(
            email: "newsletter@thebrowser.com",
            displayName: "The Browser Editors",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "The Browser Editors")
    }

    func testUpdateDisplayNameOnly_listAddressDerivedStoredTitleUpgrades() throws {
        // An address-y stored title must never freeze: the sanitizer rejects
        // it and the computation upgrades to a real name.
        let conversation = ConversationBuilder()
            .asList()
            .withListId("thebrowser.substack.com")
            .withDisplayName("newsletter@thebrowser.com")
            .build(in: context)
        addConversationParticipant(
            email: "newsletter@thebrowser.com",
            displayName: "The Browser Editors",
            to: conversation
        )
        try context.save()

        updater.updateDisplayNameOnly(for: conversation, myEmail: "me@example.com")

        XCTAssertEqual(conversation.displayName, "The Browser Editors")
    }

    @discardableResult
    private func addConversationParticipant(
        email: String,
        displayName: String?,
        to conversation: Conversation
    ) -> Person {
        let person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(displayName)
            .build(in: context)
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
        return person
    }
}
