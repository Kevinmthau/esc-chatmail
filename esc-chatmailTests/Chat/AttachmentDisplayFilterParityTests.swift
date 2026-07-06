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
}
