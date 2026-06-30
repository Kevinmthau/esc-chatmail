import XCTest
@testable import esc_chatmail

final class MessageBubbleSignatureImageTests: XCTestCase {
    func testHTMLAnalysisSuppressesCorporateSignatureBadgeImage() {
        let html = """
        <html>
        <body>
          <p>I am waiting for Paul's schedule but tentatively let's set 230pm PDT. We can adjust as needed. Please send invite.</p>
          <p>Thanks,<br>gus</p>
          <table class="signature">
            <tr><td>Gus Yeung<br>Business Development & Customer Engineering<br>Cadence</td></tr>
            <tr><td><img src="cid:fortune-badge-2025" alt="Fortune 100 Best Companies to Work For 2025"></td></tr>
          </table>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "I am waiting for Paul's schedule but tentatively let's set 230pm PDT.",
            subject: "Re: Cadence services for Anodize - introduction",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "fortune-badge-2025",
                    filename: "fortune-100-best-companies-2025.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 82_000,
                    pageCount: 0,
                    width: 520,
                    height: 650
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("fortune-badge-2025"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("fortune-badge-2025"))
    }

    func testHTMLAnalysisKeepsRealInlineContentBeforeSignatureBoundary() {
        let html = """
        <html>
        <body>
          <p>Here is the board photo.</p>
          <p><img src="cid:board-photo" alt="Board prototype on table"></p>
          <p>Thanks,<br>Alice</p>
          <div class="gmail_signature"><img src="cid:company-logo" alt="Company logo"></div>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Here is the board photo.",
            subject: "Board photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "board-photo",
                    filename: "board-photo.jpg",
                    mimeType: "image/jpeg",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 1_200_000,
                    pageCount: 0,
                    width: 1600,
                    height: 1200
                ),
                MessageBubbleAttachmentSnapshot(
                    contentId: "company-logo",
                    filename: "company-logo.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 24_000,
                    pageCount: 0,
                    width: 320,
                    height: 80
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("board-photo"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("board-photo"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("company-logo"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterGenericOnPhrase() {
        let html = """
        <html>
        <body>
          <p>Let's review this on Tuesday.</p>
          <p><img src="cid:image001.png@01DC96AF.8C2488C0" alt="Prototype photo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Let's review this on Tuesday.",
            subject: "Prototype photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image001.png@01DC96AF.8C2488C0",
                    filename: "image001.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 192_520,
                    pageCount: 0,
                    width: 512,
                    height: 512
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image001.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image001.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterGenericWrotePhrase() {
        let html = """
        <html>
        <body>
          <p>Here is what I wrote:</p>
          <p><img src="cid:image004.png@01DC96AF.8C2488C0" alt="Whiteboard photo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Here is what I wrote:",
            subject: "Whiteboard photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image004.png@01DC96AF.8C2488C0",
                    filename: "image004.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 216_512,
                    pageCount: 0,
                    width: 512,
                    height: 512
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedInlineImageAfterStandaloneWroteAttribution() {
        let html = """
        <html>
        <body>
          <p>Latest reply.</p>
          <p>John wrote:</p>
          <p><img src="cid:image005.png@01DC96AF.8C2488C0" alt="Quoted whiteboard photo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Latest reply.",
            subject: "Re: Whiteboard photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image005.png@01DC96AF.8C2488C0",
                    filename: "image005.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 218_112,
                    pageCount: 0,
                    width: 512,
                    height: 512
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image005.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image005.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterPlainHeaderLikeText() {
        let html = """
        <html>
        <body>
          <p>From: the prototype table.</p>
          <p>Sent: after the firmware update.</p>
          <p>Subject: board photo for review.</p>
          <p><img src="cid:image002.png@01DC96AF.8C2488C0" alt="Board photo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Board photo for review.",
            subject: "Board photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image002.png@01DC96AF.8C2488C0",
                    filename: "image002.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 221_184,
                    pageCount: 0,
                    width: 512,
                    height: 512
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image002.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image002.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterCasualThanksPhrase() {
        let html = """
        <html>
        <body>
          <p>Thanks, here is the image for review.</p>
          <p><img src="cid:image003.png@01DC96AF.8C2488C0" alt="Product photo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, here is the image for review.",
            subject: "Product photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image003.png@01DC96AF.8C2488C0",
                    filename: "image003.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 214_400,
                    pageCount: 0,
                    width: 512,
                    height: 512
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image003.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image003.png@01dc96af.8c2488c0"))
    }
}
