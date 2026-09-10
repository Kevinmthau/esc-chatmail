import XCTest
import CoreData
@testable import esc_chatmail

/// CX1 characterization: `Message.displayableAttachments` and
/// `ChatMessageRowModel.displayableAttachments` implement the same filter
/// (signature images → non-displayable CIDs → sender guard → referenced CIDs
/// → calendar invites, with deduplication) and must stay behaviorally
/// identical. Both copies run against one shared fixture set covering every
/// filter-relevant attachment shape, across the full flag matrix.
@MainActor
final class AttachmentDisplayFilterParityTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Shared fixture

    private struct Fixture {
        let message: Message
        let analysis: MessageBubbleHTMLAnalysis
    }

    private func normalizedCID(_ raw: String) throws -> String {
        try XCTUnwrap(EmailDocument.normalizedContentID(raw))
    }

    /// One message carrying every filter-relevant attachment shape:
    /// a regular attachment, a signature-sized image, an HTML-referenced
    /// inline image, a non-displayable inline image, a calendar invite,
    /// a content-id duplicate pair, and a file-fingerprint duplicate pair.
    private func makeFixture(
        fromMe: Bool,
        supportsCalendarInvitePreviewCard: Bool
    ) throws -> Fixture {
        var builder = MessageBuilder()
            .withId("parity-\(fromMe ? "sent" : "received")-card-\(supportsCalendarInvitePreviewCard)")
            .withSubject("Parity fixture")
            .withAttachments()
        if fromMe {
            builder = builder.fromMe()
        }
        let message = builder.build(in: context)

        _ = AttachmentBuilder()
            .withId("att-regular")
            .withContentId("CID-REGULAR")
            .asImage(width: 800, height: 600)
            .withFilename("regular.jpg")
            .withByteSize(100_000)
            .forMessage(message)
            .build(in: context)

        _ = AttachmentBuilder()
            .withId("att-signature")
            .asImage(width: 200, height: 50)
            .withFilename("signature.png")
            .withByteSize(5_000)
            .forMessage(message)
            .build(in: context)

        _ = AttachmentBuilder()
            .withId("att-inline")
            .withContentId("CID-INLINE")
            .asImage(width: 800, height: 600)
            .withFilename("inline.jpg")
            .withByteSize(100_000)
            .forMessage(message)
            .build(in: context)

        _ = AttachmentBuilder()
            .withId("att-nondisplayable")
            .withContentId("CID-NONDISPLAYABLE")
            .asImage(width: 800, height: 600)
            .withFilename("tracking.jpg")
            .withByteSize(100_000)
            .forMessage(message)
            .build(in: context)

        _ = AttachmentBuilder()
            .withId("att-invite")
            .withFilename("invite.ics")
            .withMimeType("text/calendar")
            .withByteSize(2_000)
            .forMessage(message)
            .build(in: context)

        // Content-id duplicate pair: the downloaded copy scores higher
        // (ready + localURL + byteSize) and must win.
        _ = AttachmentBuilder()
            .withId("att-dup-queued")
            .withContentId("CID-DUP")
            .withFilename("dup.pdf")
            .withMimeType("application/pdf")
            .withByteSize(0)
            .queued()
            .forMessage(message)
            .build(in: context)
        _ = AttachmentBuilder()
            .withId("att-dup-downloaded")
            .withContentId("CID-DUP")
            .withFilename("dup.pdf")
            .withMimeType("application/pdf")
            .withByteSize(9_000)
            .downloaded()
            .withLocalURL("Attachments/dup.pdf")
            .forMessage(message)
            .build(in: context)

        // File-fingerprint duplicate pair (no content id): same
        // filename/mime/size key, downloaded copy must win.
        _ = AttachmentBuilder()
            .withId("att-filedup-queued")
            .withFilename("report.pdf")
            .withMimeType("application/pdf")
            .withByteSize(50_000)
            .queued()
            .forMessage(message)
            .build(in: context)
        _ = AttachmentBuilder()
            .withId("att-filedup-downloaded")
            .withFilename("report.pdf")
            .withMimeType("application/pdf")
            .withByteSize(50_000)
            .downloaded()
            .withLocalURL("Attachments/report.pdf")
            .forMessage(message)
            .build(in: context)

        try context.save()

        let analysis = MessageBubbleHTMLAnalysis(
            hasHTMLSource: true,
            referencedInlineContentIDs: [try normalizedCID("CID-INLINE")],
            nonDisplayableInlineContentIDs: [try normalizedCID("CID-NONDISPLAYABLE")],
            supportsCalendarInvitePreviewCard: supportsCalendarInvitePreviewCard
        )
        return Fixture(message: message, analysis: analysis)
    }

    private func messageResultIDs(
        _ fixture: Fixture,
        hidingInline: Bool,
        hidingCalendar: Bool?
    ) -> [String] {
        fixture.message.displayableAttachments(
            using: fixture.analysis,
            hidingInlineReferencedInHTML: hidingInline,
            hidingCalendarInviteAttachments: hidingCalendar
        ).compactMap(\.id)
    }

    private func rowResultIDs(
        _ fixture: Fixture,
        hidingInline: Bool,
        hidingCalendar: Bool?
    ) -> [String] {
        ChatMessageRowModelMapper.map(fixture.message).displayableAttachments(
            using: fixture.analysis,
            hidingInlineReferencedInHTML: hidingInline,
            hidingCalendarInviteAttachments: hidingCalendar
        ).compactMap(\.attachmentID)
    }

    // MARK: - Parity across the flag matrix

    func testParity_bothCopiesAgreeAcrossFlagMatrix() throws {
        for fromMe in [false, true] {
            for supportsCard in [false, true] {
                let fixture = try makeFixture(
                    fromMe: fromMe,
                    supportsCalendarInvitePreviewCard: supportsCard
                )
                for hidingInline in [false, true] {
                    for hidingCalendar in [nil, false, true] as [Bool?] {
                        let fromMessage = messageResultIDs(
                            fixture, hidingInline: hidingInline, hidingCalendar: hidingCalendar
                        )
                        let fromRow = rowResultIDs(
                            fixture, hidingInline: hidingInline, hidingCalendar: hidingCalendar
                        )
                        XCTAssertEqual(
                            fromMessage, fromRow,
                            "Copies diverged for fromMe=\(fromMe) supportsCard=\(supportsCard) " +
                            "hidingInline=\(hidingInline) hidingCalendar=\(String(describing: hidingCalendar))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Pinned shared behavior

    /// Preview mode for received mail: signature, non-displayable,
    /// HTML-referenced, and calendar attachments are all hidden; duplicate
    /// pairs collapse to the downloaded copy.
    func testPinned_receivedPreviewMode_hidesInlineAndCalendar() throws {
        let fixture = try makeFixture(fromMe: false, supportsCalendarInvitePreviewCard: true)
        let expected: Set<String> = ["att-regular", "att-dup-downloaded", "att-filedup-downloaded"]

        XCTAssertEqual(Set(messageResultIDs(fixture, hidingInline: true, hidingCalendar: nil)), expected)
        XCTAssertEqual(Set(rowResultIDs(fixture, hidingInline: true, hidingCalendar: nil)), expected)
    }

    /// Bubble mode (`hidingInlineReferencedInHTML: false`) keeps referenced
    /// inline images and calendar invites, still hiding signature and
    /// non-displayable attachments and collapsing duplicates.
    func testPinned_bubbleMode_keepsInlineAndCalendar() throws {
        let fixture = try makeFixture(fromMe: false, supportsCalendarInvitePreviewCard: true)
        let expected: Set<String> = [
            "att-regular", "att-inline", "att-invite",
            "att-dup-downloaded", "att-filedup-downloaded"
        ]

        XCTAssertEqual(Set(messageResultIDs(fixture, hidingInline: false, hidingCalendar: nil)), expected)
        XCTAssertEqual(Set(rowResultIDs(fixture, hidingInline: false, hidingCalendar: nil)), expected)
    }

    /// Sent messages bypass the referenced-CID and calendar filters entirely.
    func testPinned_sentMessage_bypassesInlineFiltering() throws {
        let fixture = try makeFixture(fromMe: true, supportsCalendarInvitePreviewCard: true)
        let expected: Set<String> = [
            "att-regular", "att-inline", "att-invite",
            "att-dup-downloaded", "att-filedup-downloaded"
        ]

        XCTAssertEqual(Set(messageResultIDs(fixture, hidingInline: true, hidingCalendar: nil)), expected)
        XCTAssertEqual(Set(rowResultIDs(fixture, hidingInline: true, hidingCalendar: nil)), expected)
    }

    /// The calendar filter defaults to the analysis flag and is overridable
    /// in both directions.
    func testPinned_calendarFilterFollowsAnalysisFlagAndOverride() throws {
        let fixture = try makeFixture(fromMe: false, supportsCalendarInvitePreviewCard: false)
        let withInvite: Set<String> = [
            "att-regular", "att-invite", "att-dup-downloaded", "att-filedup-downloaded"
        ]
        let withoutInvite: Set<String> = [
            "att-regular", "att-dup-downloaded", "att-filedup-downloaded"
        ]

        // supportsCard=false + nil override → invite stays.
        XCTAssertEqual(Set(messageResultIDs(fixture, hidingInline: true, hidingCalendar: nil)), withInvite)
        XCTAssertEqual(Set(rowResultIDs(fixture, hidingInline: true, hidingCalendar: nil)), withInvite)

        // Explicit true hides it; explicit false keeps it.
        XCTAssertEqual(Set(messageResultIDs(fixture, hidingInline: true, hidingCalendar: true)), withoutInvite)
        XCTAssertEqual(Set(rowResultIDs(fixture, hidingInline: true, hidingCalendar: true)), withoutInvite)
        XCTAssertEqual(Set(messageResultIDs(fixture, hidingInline: true, hidingCalendar: false)), withInvite)
        XCTAssertEqual(Set(rowResultIDs(fixture, hidingInline: true, hidingCalendar: false)), withInvite)
    }
    func testUnsignedLogoDeliveryRemainsDisplayableBeforeAndAfterDownload() {
        for (width, height): (Int16, Int16) in [(0, 0), (600, 600)] {
            for prefix in ["", "<p>Please use this new logo for the launch.</p>"] {
                let message = MessageBuilder().withAttachments().build(in: context)
                let attachment = AttachmentBuilder().withId("delivered-logo").withContentId("artwork")
                    .withFilename("agency-logo.png").asImage(width: width, height: height)
                    .withByteSize(50_000).forMessage(message).build(in: context)
                attachment.state = width == 0 ? .queued : .downloaded
                let html = prefix + "<p><img src='cid:artwork'></p>"
                let analysis = MessageBubbleHTMLAnalysisBuilder.build(
                    canonicalHTML: html, hasHTMLSourceHint: true, isForwardedEmail: false,
                    isLikelyCalendarInvite: false, bodyText: nil, cleanedSnippet: nil,
                    subject: nil, attachmentSnapshots: [attachment.bubbleSnapshot]
                )
                let fixture = Fixture(message: message, analysis: analysis)
                XCTAssertEqual(messageResultIDs(fixture, hidingInline: false, hidingCalendar: false), ["delivered-logo"])
                XCTAssertEqual(rowResultIDs(fixture, hidingInline: false, hidingCalendar: false), ["delivered-logo"])
            }
        }
    }

    // Revert-check: download selection uses the unfiltered row, including hidden candidates.
    func testQueuedUnknownInlineDownloadsSurviveSignatureSuppression() throws {
        let message = MessageBuilder().withId("hidden-inline-download").withAttachments().build(in: context)
        _ = AttachmentBuilder().withId("queued-logo").withContentId("image001")
            .asImage(width: 0, height: 0).withByteSize(50_000).queued()
            .forMessage(message).build(in: context)
        _ = AttachmentBuilder().withId("known-image").withContentId("known")
            .asImage(width: 1200, height: 800).withByteSize(50_000).queued()
            .forMessage(message).build(in: context)
        _ = AttachmentBuilder().withId("regular-file").asImage(width: 0, height: 0)
            .withByteSize(50_000).queued().forMessage(message).build(in: context)
        let row = ChatMessageRowModelMapper.map(message)
        let analysis = MessageBubbleHTMLAnalysis(hasHTMLSource: true,
            referencedInlineContentIDs: ["image001"], nonDisplayableInlineContentIDs: ["image001"],
            supportsCalendarInvitePreviewCard: false)
        XCTAssertFalse(row.displayableAttachments(using: analysis, hidingInlineReferencedInHTML: false)
            .contains { $0.attachmentID == "queued-logo" })
        XCTAssertEqual(InlineAttachmentDownloadPolicy.pendingImages(in: row.attachments, isFromMe: false)
            .compactMap(\.attachmentID), ["queued-logo"])
        XCTAssertTrue(InlineAttachmentDownloadPolicy.pendingImages(in: row.attachments, isFromMe: true).isEmpty)
    }

    // Revert-check: received text-only CID survivors get bounded presentation;
    // body photos, large images, sent mail and regular attachments keep their path.
    func testInlineImagePresentationPreservesBodyPhotosAndRegularAttachments() {
        let message = MessageBuilder().withId("inline-presentation").withAttachments().build(in: context)
        let image = AttachmentBuilder().withId("inline").withContentId("BODY")
            .asImage(width: 300, height: 300).withByteSize(50_000).downloaded()
            .forMessage(message).build(in: context)
        func policy(sent: Bool = false, preview: Bool = false, body: Set<String> = []) -> InlineImagePresentationPolicy {
            InlineImagePresentationPolicy.resolve(attachment: image, isFromMe: sent, isHTMLPreview: preview, bodyContentIDs: body)
        }
        XCTAssertEqual(policy(), .compact)
        XCTAssertEqual(policy(sent: true), .standard)
        XCTAssertEqual(policy(preview: true), .standard)
        XCTAssertEqual(policy(body: ["body"]), .standard)
        image.width = 1200
        image.height = 400
        XCTAssertEqual(policy(), .standard)
        image.width = 0
        image.height = 0
        image.state = .queued
        XCTAssertEqual(policy(), .collapsed)
        XCTAssertEqual(policy(sent: true), .standard)
        image.state = .failed
        XCTAssertEqual(policy(), .standard)
        image.state = .downloaded
        XCTAssertEqual(policy(), .standard, "Missing metadata must not produce a zero-size decoded image")
        image.contentId = nil
        image.state = .queued
        XCTAssertEqual(policy(), .standard)
    }

    func testInlineImageSizingFitsWithoutUpscalingNativePixels() {
        XCTAssertEqual(InlineImagePresentationPolicy.fittedSize(pixelWidth: 300, pixelHeight: 300, maxWidth: 260, displayScale: 3), CGSize(width: 100, height: 100))
        XCTAssertEqual(InlineImagePresentationPolicy.fittedSize(pixelWidth: 900, pixelHeight: 900, maxWidth: 260, displayScale: 3), CGSize(width: 160, height: 160))
        XCTAssertEqual(InlineImagePresentationPolicy.fittedSize(pixelWidth: 600, pixelHeight: 150, maxWidth: 100, displayScale: 3), CGSize(width: 100, height: 25))
    }

    // Revert-check: failure remains actionable even when containment/DOM cleanup
    // suppressed the CID. Explicit retry avoids a hide/fail/onAppear retry loop.
    func testFailedUnknownInlineImageKeepsRetryAcrossBothDisplayRepresentations() {
        let message = MessageBuilder().withId("inline-retry").withAttachments().build(in: context)
        let image = AttachmentBuilder().withId("failed-inline").withContentId("failed-image")
            .asImage(width: 0, height: 0).withByteSize(50_000).queued().forMessage(message).build(in: context)
        image.state = .failed
        let analysis = MessageBubbleHTMLAnalysis(hasHTMLSource: true,
            referencedInlineContentIDs: ["failed-image"], nonDisplayableInlineContentIDs: ["failed-image"],
            supportsCalendarInvitePreviewCard: false)
        let fixture = Fixture(message: message, analysis: analysis)
        XCTAssertEqual(messageResultIDs(fixture, hidingInline: false, hidingCalendar: false), ["failed-inline"])
        XCTAssertEqual(rowResultIDs(fixture, hidingInline: false, hidingCalendar: false), ["failed-inline"])
        XCTAssertTrue(rowResultIDs(fixture, hidingInline: true, hidingCalendar: false).isEmpty)
        XCTAssertTrue(InlineImagePresentationPolicy.requiresExplicitRetry(attachment: image, isFromMe: false))
        XCTAssertFalse(InlineImagePresentationPolicy.requiresExplicitRetry(attachment: image, isFromMe: true))
    }

    func testAnalysisMarksPhotoBeforeOutlookSignOffAsBodyContent() {
        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: "<p>Photo from the job.</p><p><img src='cid:body'></p><p>Best,<o:p></o:p></p><p>Jane</p><p>Account Manager</p><p><img src='cid:after'></p>",
            hasHTMLSourceHint: true, isForwardedEmail: false, isLikelyCalendarInvite: false,
            bodyText: nil, cleanedSnippet: nil, subject: nil, attachmentSnapshots: []
        )
        XCTAssertEqual(analysis.bodyInlineContentIDs, ["body"])
    }

    func testAnalysisPreservesOrdinaryPhotosWithoutCorroboratedSignature() {
        for prefix in ["<p>Thanks, here is the photo.</p>", "<p>Thanks,<o:p></o:p></p><p>Jane</p>"] {
            let analysis = MessageBubbleHTMLAnalysisBuilder.build(
                canonicalHTML: prefix + "<p><img src='cid:body'></p>",
                hasHTMLSourceHint: true, isForwardedEmail: false, isLikelyCalendarInvite: false,
                bodyText: nil, cleanedSnippet: nil, subject: nil, attachmentSnapshots: []
            )
            XCTAssertEqual(analysis.bodyInlineContentIDs, ["body"])
        }
    }

}
