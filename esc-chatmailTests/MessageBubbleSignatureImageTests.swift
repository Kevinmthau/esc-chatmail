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

    func testHTMLAnalysisKeepsGeneratedImageAfterUncorroboratedSignatureClass() {
        let html = """
        <html>
        <body>
          <div class="signature-collection-hero">
            <p>Shop the new Signature Collection.</p>
            <p><img src="cid:image050.png@01DC96AF.8C2488C0" alt="Signature Collection product"></p>
          </div>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Shop the new Signature Collection.",
            subject: "Signature Collection",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image050.png@01DC96AF.8C2488C0",
                    filename: "image050.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image050.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image050.png@01dc96af.8c2488c0"))
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

    func testHTMLAnalysisSuppressesGeneratedInlineImageAfterBoldReplyHeaderSequence() {
        let html = """
        <html>
        <body>
          <p>Latest reply.</p>
          <p><b>From:</b> Alice Example &lt;alice@example.com&gt;</p>
          <p><b>Sent:</b> Monday, January 1, 2026 9:00 AM</p>
          <p><b>To:</b> Bob Example &lt;bob@example.com&gt;</p>
          <p><b>Subject:</b> Re: Whiteboard photo</p>
          <p>Older quoted content.</p>
          <p><img src="cid:image008.png@01DC96AF.8C2488C0" alt="Quoted whiteboard photo"></p>
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
                    contentId: "image008.png@01DC96AF.8C2488C0",
                    filename: "image008.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image008.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image008.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageBeforeLaterReplyHeader() {
        let currentReplyDetails = String(
            repeating: "Current reply detail with enough text before the inline image. ",
            count: 60
        )
        let html = """
        <html>
        <body>
          <p>\(currentReplyDetails)</p>
          <p><img src="cid:image009.png@01DC96AF.8C2488C0" alt="Current reply diagram"></p>
          <p><b>From:</b> Alice Example &lt;alice@example.com&gt;</p>
          <p><b>Sent:</b> Monday, January 1, 2026 9:00 AM</p>
          <p><b>To:</b> Bob Example &lt;bob@example.com&gt;</p>
          <p><b>Subject:</b> Re: Whiteboard photo</p>
          <p>Older quoted content.</p>
          <p><img src="cid:image010.png@01DC96AF.8C2488C0" alt="Quoted whiteboard photo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Current reply detail with enough text before the inline image.",
            subject: "Re: Whiteboard photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image009.png@01DC96AF.8C2488C0",
                    filename: "image009.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 218_112,
                    pageCount: 0,
                    width: 512,
                    height: 512
                ),
                MessageBubbleAttachmentSnapshot(
                    contentId: "image010.png@01DC96AF.8C2488C0",
                    filename: "image010.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image009.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image009.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image010.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesCurrentSignatureImageBeforeLaterReplyHeader() {
        let currentReplyDetails = String(
            repeating: "Current reply detail before the signature block. ",
            count: 60
        )
        let html = """
        <html>
        <body>
          <p>\(currentReplyDetails)</p>
          <p>Warmly,</p>
          <p>Katherine</p>
          <p><strong>Katherine Merwin</strong></p>
          <p>Global Membership Manager</p>
          <p><img src="cid:image011.png@01DC96AF.8C2488C0" alt="logo"></p>
          <p><b>From:</b> Alice Example &lt;alice@example.com&gt;</p>
          <p><b>Sent:</b> Monday, January 1, 2026 9:00 AM</p>
          <p><b>To:</b> Bob Example &lt;bob@example.com&gt;</p>
          <p><b>Subject:</b> Re: Whiteboard photo</p>
          <p>Older quoted content.</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Current reply detail before the signature block.",
            subject: "Re: Whiteboard photo",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image011.png@01DC96AF.8C2488C0",
                    filename: "image011.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 192_520,
                    pageCount: 0,
                    width: 134,
                    height: 53
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image011.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image011.png@01dc96af.8c2488c0"))
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

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterBoldBodyFromLabel() {
        let html = """
        <html>
        <body>
          <p><b>From:</b> the prototype table.</p>
          <p><strong>Subject:</strong> board photo for review.</p>
          <p><img src="cid:image006.png@01DC96AF.8C2488C0" alt="Board photo"></p>
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
                    contentId: "image006.png@01DC96AF.8C2488C0",
                    filename: "image006.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image006.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image006.png@01dc96af.8c2488c0"))
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

    func testHTMLAnalysisKeepsGeneratedEngineeringDiagramAfterCasualThanksPhrase() {
        let html = """
        <html>
        <body>
          <p>Thanks, please review the engineering diagram below.</p>
          <p><img src="cid:image007.png@01DC96AF.8C2488C0" alt="Engineering diagram"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, please review the engineering diagram below.",
            subject: "Engineering diagram",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image007.png@01DC96AF.8C2488C0",
                    filename: "image007.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image007.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image007.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedMobileAppScreenshotAfterCasualThanksPhrase() {
        let html = """
        <html>
        <body>
          <p>Thanks, please review the mobile app screenshot below.</p>
          <p><img src="cid:image014.png@01DC96AF.8C2488C0" alt="Mobile app screenshot"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, please review the mobile app screenshot below.",
            subject: "Mobile app screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image014.png@01DC96AF.8C2488C0",
                    filename: "image014.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image014.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image014.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedMobileAppScreenshotAfterStandaloneThanksLine() {
        let html = """
        <html>
        <body>
          <p>Thanks,<br>Please review the mobile app screenshot below.</p>
          <p><img src="cid:image016.png@01DC96AF.8C2488C0" alt="Mobile app screenshot"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, please review the mobile app screenshot below.",
            subject: "Mobile app screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image016.png@01DC96AF.8C2488C0",
                    filename: "image016.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image016.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image016.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageWithEmailLikeCIDAfterStandaloneThanksLine() {
        let html = """
        <html>
        <body>
          <p>Thanks,</p>
          <p><img src="cid:image034@example.com" alt="Current reply screenshot"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks.",
            subject: "Current reply screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image034@example.com",
                    filename: "image034.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image034@example.com"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image034@example.com"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageBeforeLaterContactBodyTextAfterStandaloneThanksLine() {
        let html = """
        <html>
        <body>
          <p>Thanks,</p>
          <p><img src="cid:image043.png@01DC96AF.8C2488C0" alt="Current reply screenshot"></p>
          <p>Please email support@example.com if this still looks off.</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks. Please email support@example.com if this still looks off.",
            subject: "Current reply screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image043.png@01DC96AF.8C2488C0",
                    filename: "image043.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image043.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image043.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesLogoOnlySignatureAfterStandaloneThanks() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam</p>
          <p><img src="cid:image013.png@01DC96AF.8C2488C0" alt="Company logo"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image013.png@01DC96AF.8C2488C0",
                    filename: "image013.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image013.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image013.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeBeforeFollowingBrandingSignal() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br><img src="cid:image035.png@01DC96AF.8C2488C0" alt=""><br>Acme logo</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image035.png@01DC96AF.8C2488C0",
                    filename: "image035.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image035.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image035.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeBeforeDistantBrandingSignal() {
        let markupSpacer = String(
            repeating: #"<span style="display:none">&nbsp;</span>"#,
            count: 40
        )
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br><img src="cid:image041.png@01DC96AF.8C2488C0" alt="">\(markupSpacer)<br>Acme logo</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image041.png@01DC96AF.8C2488C0",
                    filename: "image041.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image041.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image041.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyFigureBeforeBrandingTextAfterStandaloneThanksLine() {
        let html = """
        <html>
        <body>
          <p>Thanks,</p>
          <p>Figure</p>
          <p><img src="cid:image036.png@01DC96AF.8C2488C0" alt="Cadence chart"></p>
          <p>Cadence chart details</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, figure, cadence chart details.",
            subject: "Cadence chart",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image036.png@01DC96AF.8C2488C0",
                    filename: "image036.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image036.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image036.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterBrandingBodyTextAfterStandaloneThanksLine() {
        let html = """
        <html>
        <body>
          <p>Thanks,</p>
          <p>Cadence chart below.</p>
          <p><img src="cid:image046.png@01DC96AF.8C2488C0" alt="Cadence chart"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks. Cadence chart below.",
            subject: "Cadence chart",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image046.png@01DC96AF.8C2488C0",
                    filename: "image046.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image046.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image046.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterStandaloneBrandingTextSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br>Acme logo<br><img src="cid:image047.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image047.png@01DC96AF.8C2488C0",
                    filename: "image047.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image047.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image047.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterStandaloneContactSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam</p>
          <p>Mobile +1 555 0100</p>
          <p><img src="cid:image015.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image015.png@01DC96AF.8C2488C0",
                    filename: "image015.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image015.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image015.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterLinkedContactSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam</p>
          <p><a href=mailto:sam@example.com>sam@example.com</a></p>
          <p><img src="cid:image017.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image017.png@01DC96AF.8C2488C0",
                    filename: "image017.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image017.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image017.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterSameLineSignOffName() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks, Sam<br><a href="mailto:sam@example.com">sam@example.com</a><br><img src="cid:image029.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image029.png@01DC96AF.8C2488C0",
                    filename: "image029.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image029.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image029.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterSameLineSignOffNameWithEntitySpacing() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,&nbsp;Sam<br><a href="mailto:sam@example.com">sam@example.com</a><br><img src="cid:image038.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image038.png@01DC96AF.8C2488C0",
                    filename: "image038.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image038.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image038.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterSameLineSignOffNameWithEntityApostrophe() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks, O&#39;Connor<br><a href="mailto:sam@example.com">sam@example.com</a><br><img src="cid:image039.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image039.png@01DC96AF.8C2488C0",
                    filename: "image039.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image039.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image039.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterRichMarkupSignatureSpacer() {
        let markupSpacer = String(
            repeating: #"<tr><td style="padding:0;border:0;color:#555">&nbsp;</td></tr>"#,
            count: 26
        )
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <table><tbody><tr><td>Thanks,<br>Sam</td></tr>\(markupSpacer)<tr><td><a href="mailto:sam@example.com">sam@example.com</a></td></tr><tr><td><img src="cid:image037.png@01DC96AF.8C2488C0" alt=""></td></tr></tbody></table>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image037.png@01DC96AF.8C2488C0",
                    filename: "image037.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image037.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image037.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterRichTextSameLineSignOffName() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks, <span>Sam</span><br><a href="mailto:sam@example.com">sam@example.com</a><br><img src="cid:image031.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image031.png@01DC96AF.8C2488C0",
                    filename: "image031.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image031.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image031.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterBoldSameLineSignOffName() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p><b>Thanks,</b> Sam<br><a href="mailto:sam@example.com">sam@example.com</a><br><img src="cid:image032.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image032.png@01DC96AF.8C2488C0",
                    filename: "image032.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image032.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image032.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterSameLineSignOffInitial() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks, J<br><a href="mailto:j@example.com">j@example.com</a><br><img src="cid:image030.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image030.png@01DC96AF.8C2488C0",
                    filename: "image030.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image030.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image030.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterBlockedWordSameLineInitial() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks, A<br><a href="mailto:a@example.com">a@example.com</a><br><img src="cid:image040.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image040.png@01DC96AF.8C2488C0",
                    filename: "image040.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image040.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image040.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterLaterStandaloneContactSignature() {
        let currentReplyDetails = String(
            repeating: "Current reply detail before the final signature. ",
            count: 40
        )
        let html = """
        <html>
        <body>
          <p>Thanks,</p>
          <p>\(currentReplyDetails)</p>
          <p>Regards,</p>
          <p>Sam Example</p>
          <p><a href="mailto:sam@example.com">sam@example.com</a></p>
          <p><img src="cid:image018.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Current reply detail before the final signature.",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image018.png@01DC96AF.8C2488C0",
                    filename: "image018.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image018.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image018.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageBeforeLaterStandaloneContactSignature() {
        let currentReplyDetails = String(
            repeating: "Current reply detail before the real inline image. ",
            count: 8
        )
        let html = """
        <html>
        <body>
          <p>Thanks,</p>
          <p>\(currentReplyDetails)</p>
          <p><img src="cid:image020.png@01DC96AF.8C2488C0" alt="Current reply screenshot"></p>
          <p>Regards,</p>
          <p>Sam Example</p>
          <p><a href="mailto:sam@example.com">sam@example.com</a></p>
          <p><img src="cid:image021.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Current reply detail before the real inline image.",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image020.png@01DC96AF.8C2488C0",
                    filename: "image020.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 214_400,
                    pageCount: 0,
                    width: 512,
                    height: 512
                ),
                MessageBubbleAttachmentSnapshot(
                    contentId: "image021.png@01DC96AF.8C2488C0",
                    filename: "image021.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image020.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image020.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image021.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterEarlyThanksBeforeLaterStandaloneContactSignature() {
        let leadIn = String(
            repeating: "Current reply detail before the inline figure ",
            count: 40
        )
        let html = """
        <html>
        <body>
          <p>\(leadIn)</p>
          <p>Thanks,</p>
          <p>Figure</p>
          <p><img src="cid:image026.png@01DC96AF.8C2488C0" alt="Current reply figure"></p>
          <p>Regards,</p>
          <p>Sam Example</p>
          <p><a href="mailto:sam@example.com">sam@example.com</a></p>
          <p><img src="cid:image027.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Current reply detail before the inline figure.",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image026.png@01DC96AF.8C2488C0",
                    filename: "image026.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 214_400,
                    pageCount: 0,
                    width: 512,
                    height: 512
                ),
                MessageBubbleAttachmentSnapshot(
                    contentId: "image027.png@01DC96AF.8C2488C0",
                    filename: "image027.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image026.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image026.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image027.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterUnsubscribeFooterSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam</p>
          <p><a href="https://example.com/unsubscribe">Unsubscribe</a></p>
          <p><img src="cid:image019.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image019.png@01DC96AF.8C2488C0",
                    filename: "image019.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image019.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image019.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterLongUnsubscribeFooterURL() {
        let token = String(repeating: "abcdef", count: 35)
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam</p>
          <p><a href="https://example.com/unsubscribe?token=\(token)&source=signature-footer">Unsubscribe</a></p>
          <p><img src="cid:image042.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image042.png@01DC96AF.8C2488C0",
                    filename: "image042.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image042.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image042.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterInlineWrappedSignOff() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p><span>Thanks,</span><br>Sam<br><a href="mailto:sam@example.com">sam@example.com</a></p>
          <p><img src="cid:image022.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image022.png@01DC96AF.8C2488C0",
                    filename: "image022.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image022.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image022.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeWithAbbreviatedRoleBeforeContact() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br>Sr. Director<br><img src="cid:image028.png@01DC96AF.8C2488C0" alt=""><br><a href="mailto:sam@example.com">sam@example.com</a></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image028.png@01DC96AF.8C2488C0",
                    filename: "image028.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image028.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image028.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterAbbreviatedRoleSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br>Sr. Director<br><img src="cid:image033.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image033.png@01DC96AF.8C2488C0",
                    filename: "image033.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image033.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image033.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterSplitMobileContactSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br>Mobile<br>+1 555 0100</p>
          <p><img src="cid:image023.png@01DC96AF.8C2488C0" alt=""></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image023.png@01DC96AF.8C2488C0",
                    filename: "image023.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image023.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image023.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeBeforeFollowingSplitMobileContactSignature() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks,<br>Sam<br><img src="cid:image025.png@01DC96AF.8C2488C0" alt=""><br>Mobile<br>+1 555 0100</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image025.png@01DC96AF.8C2488C0",
                    filename: "image025.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image025.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image025.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedBadgeAfterSameLineSignOffBeforeFollowingSplitMobileContact() {
        let html = """
        <html>
        <body>
          <p>Can you take a look?</p>
          <p>Thanks, Sam<br><img src="cid:image044.png@01DC96AF.8C2488C0" alt=""><br>Mobile<br>+1 555 0100</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Can you take a look?",
            subject: "Review",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image044.png@01DC96AF.8C2488C0",
                    filename: "image044.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image044.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image044.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedBodyImageAfterSameLineSignOffBeforeLaterContactBodyText() {
        let html = """
        <html>
        <body>
          <p>Thanks, Sam<br><img src="cid:image045.png@01DC96AF.8C2488C0" alt="Current reply screenshot"></p>
          <p>Email support@example.com if this still looks off.</p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, Sam. Email support@example.com if this still looks off.",
            subject: "Current reply screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image045.png@01DC96AF.8C2488C0",
                    filename: "image045.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image045.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image045.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedUnsubscribeSettingsScreenshotAfterStandaloneThanksLine() {
        let html = """
        <html>
        <body>
          <p>Thanks,<br>Please review the unsubscribe settings screenshot below.</p>
          <p><img src="cid:image024.png@01DC96AF.8C2488C0" alt="Unsubscribe settings screenshot"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, please review the unsubscribe settings screenshot below.",
            subject: "Unsubscribe settings screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image024.png@01DC96AF.8C2488C0",
                    filename: "image024.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image024.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image024.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisKeepsGeneratedLogoMockupAfterCasualThanksPhrase() {
        let html = """
        <html>
        <body>
          <p>Thanks, here is the logo mockup for review.</p>
          <p><img src="cid:image012.png@01DC96AF.8C2488C0" alt="Logo mockup"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Thanks, here is the logo mockup for review.",
            subject: "Logo mockup",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image012.png@01DC96AF.8C2488C0",
                    filename: "image012.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image012.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image012.png@01dc96af.8c2488c0"))
    }

    // MARK: - DOM structural containment

    // The same generated-named, content-sized image is keep-or-drop purely on
    // whether its DOM ancestor is a signature/quote container — not on its
    // dimensions or filename.

    func testHTMLAnalysisKeepsGeneratedContentImageNotInsideAnyContainer() {
        let html = """
        <html>
        <body>
          <p>Here is the latest mock for review.</p>
          <p><img src="cid:image004.png@01DC96AF.8C2488C0" alt="Latest mock"></p>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Here is the latest mock for review.",
            subject: "Latest mock",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image004.png@01DC96AF.8C2488C0",
                    filename: "image004.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesGeneratedImageInsideGmailSignatureContainer() {
        let html = """
        <html>
        <body>
          <p>Here is the latest mock for review.</p>
          <div class="gmail_signature">
            <img src="cid:image004.png@01DC96AF.8C2488C0" alt="Latest mock">
          </div>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Here is the latest mock for review.",
            subject: "Latest mock",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image004.png@01DC96AF.8C2488C0",
                    filename: "image004.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesLargeImageInsideGmailSignatureContainerRegardlessOfDimensions() {
        // A signature image larger than any dimension cap — only structural
        // containment can classify it, which is the whole point of the DOM path.
        let html = """
        <html>
        <body>
          <p>Here is the latest mock for review.</p>
          <div class="gmail_signature">
            <img src="cid:banner-asset" alt="Wide corporate banner">
          </div>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Here is the latest mock for review.",
            subject: "Latest mock",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "banner-asset",
                    filename: "banner.png",
                    mimeType: "image/png",
                    stateRaw: Attachment.State.downloaded.rawValue,
                    localURL: nil,
                    byteSize: 320_000,
                    pageCount: 0,
                    width: 1400,
                    height: 1100
                )
            ]
        )

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("banner-asset"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("banner-asset"))
    }

    func testHTMLAnalysisKeepsImageReferencedInBodyEvenWhenAlsoInsideQuotedContainer() {
        // The same attachment is shown in the live body AND re-referenced inside
        // a quoted container. Containment must NOT hide it — the body
        // legitimately displays it. (Without the "only inside" exclusivity guard
        // the containment path would wrongly suppress the shared CID.) The
        // blockquote carries no sign-off / "On … wrote:" text, so the
        // text-boundary heuristic does not fire and this isolates the
        // containment decision.
        let html = """
        <html>
        <body>
          <p>Here is the screenshot we discussed.</p>
          <p><img src="cid:shared-shot" alt="Screenshot in body"></p>
          <blockquote type="cite">
            <p><img src="cid:shared-shot" alt="Screenshot quoted"></p>
          </blockquote>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "Here is the screenshot we discussed.",
            subject: "Screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "shared-shot",
                    filename: "screenshot.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("shared-shot"))
        XCTAssertFalse(analysis.nonDisplayableInlineContentIDs.contains("shared-shot"))
    }

    func testHTMLAnalysisSuppressesGeneratedImageInsideQuotedBlockquote() {
        let html = """
        <html>
        <body>
          <p>See the quoted screenshot.</p>
          <blockquote type="cite">
            <p>On Monday, Alice wrote:</p>
            <p><img src="cid:image004.png@01DC96AF.8C2488C0" alt="Quoted screenshot"></p>
          </blockquote>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: "See the quoted screenshot.",
            subject: "Re: Screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image004.png@01DC96AF.8C2488C0",
                    filename: "image004.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
    }

    func testHTMLAnalysisSuppressesQuotedInlineImageWhenWholeMessageIsQuoted() {
        // No meaningful content remains after stripping the quote, so the
        // `removedByHTMLCleanup` path falls back and keeps the image. Structural
        // containment still classifies it as quoted.
        let html = """
        <html>
        <body>
          <blockquote type="cite">
            <p>On Monday, Alice wrote:</p>
            <p><img src="cid:image004.png@01DC96AF.8C2488C0" alt="Quoted screenshot"></p>
          </blockquote>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: nil,
            subject: "Re: Screenshot",
            attachmentSnapshots: [
                MessageBubbleAttachmentSnapshot(
                    contentId: "image004.png@01DC96AF.8C2488C0",
                    filename: "image004.png",
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

        XCTAssertTrue(analysis.referencedInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
        XCTAssertTrue(analysis.nonDisplayableInlineContentIDs.contains("image004.png@01dc96af.8c2488c0"))
    }
}
