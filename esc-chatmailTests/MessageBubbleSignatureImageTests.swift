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
}
