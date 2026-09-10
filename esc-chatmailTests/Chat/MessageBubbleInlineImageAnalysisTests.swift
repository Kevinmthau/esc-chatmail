import XCTest
@testable import esc_chatmail

final class MessageBubbleInlineImageAnalysisTests: XCTestCase {
    private let signOff = "<p>Sincerely,<o:p></o:p></p><p>Jane Doe</p><p>Account Manager</p>"

    // Revert-check: o:p whitespace and corroborated-region identity/dimension rules.
    func testSuppressesBadgesAcrossMailClientIdentitiesAfterOutlookSignOff() {
        for (cid, filename) in [
            ("image001.png@outlook", "image001.png"),
            ("ii_m1abc2de0", "image.png"),
            ("b5606509-5d31-4c75-a6aa-392ad73c86dc", "PastedGraphic-1.png"),
            ("outlook-abcd1234", "Outlook-abcd1234.png"),
            ("part1.abcd.1234@example", "attachment.png"),
            ("custom-artwork", "agency.png")
        ] {
            XCTAssertTrue(analyze(prefix: signOff, cid: cid, filename: filename).nonDisplayableInlineContentIDs.contains(cid), filename)
        }
    }

    // Revert-check: a standalone sign-off needs role/contact corroboration.
    func testKeepsBodyScreenshotAfterUncorroboratedOutlookThanks() {
        XCTAssertTrue(analyze(prefix: "<p>Thanks,<o:p></o:p></p><p>Jane</p>").nonDisplayableInlineContentIDs.isEmpty)
    }

    func testKeepsBodyPhotosBeforeSignOffIncludingLogoNamedReviewAsset() {
        for filename in ["image001.png", "agency-logo.png"] {
            XCTAssertTrue(analyze(filename: filename, suffix: signOff).nonDisplayableInlineContentIDs.isEmpty)
        }
    }

    func testKeepsBodyPhotoWhenInstructionsFollowItsCID() {
        XCTAssertTrue(analyze(prefix: signOff, suffix: "<p>Please review the attached photo.</p>").nonDisplayableInlineContentIDs.isEmpty)
    }

    // Revert-check: zero-dimension generated names qualify only in corroborated regions.
    func testSuppressesQueuedGeneratedBadgesButKeepsUnknownCameraPhotos() {
        for filename in ["image1.png", "PastedGraphic-1.png", "Outlook-abcd1234.png"] {
            XCTAssertFalse(analyze(prefix: signOff, cid: "custom", filename: filename, width: 0, height: 0).nonDisplayableInlineContentIDs.isEmpty, filename)
        }
        XCTAssertTrue(analyze(prefix: signOff, cid: "custom", filename: "IMG_1234.jpg", width: 0, height: 0).nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(width: 0, height: 0).nonDisplayableInlineContentIDs.isEmpty)
    }

    // Revert-check: snapshot dimensions take precedence over HTML size hints.
    func testUsesHTMLDimensionsOnlyUntilRealDimensionsArrive() {
        XCTAssertFalse(analyze(prefix: signOff, cid: "custom", filename: "artwork.png", width: 0, height: 0, attributes: "width='300' height='200'").nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(prefix: signOff, width: 0, height: 0, attributes: "width=1200 height=1000").nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(prefix: signOff, width: 1400, height: 1000, attributes: "width='300' height='200'").nonDisplayableInlineContentIDs.isEmpty)
    }

    func testSuppressesShortBannerButKeepsLargePhotos() {
        XCTAssertFalse(analyze(prefix: signOff, width: 1200, height: 300).nonDisplayableInlineContentIDs.isEmpty)
        // The audit's 1200x400 example contradicts its 300px banner ceiling.
        // Keep the conservative ceiling so a wide body photo remains available.
        for (width, height): (Int16, Int16) in [(1200, 400), (1000, 1000), (600, 1200)] {
            XCTAssertTrue(analyze(prefix: signOff, width: width, height: height).nonDisplayableInlineContentIDs.isEmpty)
        }
    }

    // Revert-check: keywords work without a section signal, bounded by size/prose.
    func testSuppressesKeywordLogoWithoutSignOffButKeepsReviewMockupAndLargePhoto() {
        XCTAssertFalse(analyze(filename: "agency-logo.png").nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(filename: "logo-mockup.png", suffix: "<p>Please review this draft.</p>").nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(filename: "agency-logo.png", width: 1200, height: 1000).nonDisplayableInlineContentIDs.isEmpty)
    }

    func testKeepsUnknownFailedBadgeAvailableForRetry() {
        XCTAssertTrue(analyze(prefix: signOff, width: 0, height: 0, state: .failed).nonDisplayableInlineContentIDs.isEmpty)
    }

    func testSentAttachmentsKeepExistingIdentityAndDimensionGates() {
        XCTAssertTrue(analyze(prefix: signOff, cid: "custom", filename: "agency.png", isFromMe: true).nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(prefix: signOff, width: 0, height: 0, isFromMe: true).nonDisplayableInlineContentIDs.isEmpty)
        XCTAssertTrue(analyze(filename: "agency-logo.png", isFromMe: true).nonDisplayableInlineContentIDs.isEmpty)
    }

    // Revert-check: the image builder uses the shared sign-off vocabulary.
    func testEveryCanonicalSignOffCorroboratesImageRegionWithoutMatchingProse() {
        for phrase in SignaturePatterns.signOffPhrases {
            let prefix = "<p>\(phrase),<o:p></o:p></p><p>Jane Doe</p><p>Account Manager</p>"
            XCTAssertFalse(analyze(prefix: prefix).nonDisplayableInlineContentIDs.isEmpty, phrase)
        }
        XCTAssertTrue(analyze(prefix: "<p>Best regards for the launch<br></p>").nonDisplayableInlineContentIDs.isEmpty)
    }

    func testUnknownDownloadFailureInvalidatesAnalysisFingerprint() {
        let queued = snapshot(width: 0, height: 0, state: .queued)
        let failed = snapshot(width: 0, height: 0, state: .failed)
        XCTAssertNotEqual(MessageBubbleAttachmentSnapshot.analysisFingerprint(for: [queued]), MessageBubbleAttachmentSnapshot.analysisFingerprint(for: [failed]))
    }

    private func analyze(
        prefix: String = "",
        cid: String = "image001.png@outlook",
        filename: String = "image001.png",
        suffix: String = "",
        width: Int16 = 300,
        height: Int16 = 300,
        attributes: String = "",
        state: Attachment.State = .queued,
        isFromMe: Bool = false
    ) -> MessageBubbleHTMLAnalysis {
        let html = "<p>The application is ready.</p>" + prefix + "<p><img src='cid:\(cid)' \(attributes)></p>" + suffix
        return MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html, hasHTMLSourceHint: true, isForwardedEmail: false,
            isFromMe: isFromMe, isLikelyCalendarInvite: false, bodyText: nil,
            cleanedSnippet: nil, subject: nil,
            attachmentSnapshots: [snapshot(cid: cid, filename: filename, width: width, height: height, state: state)]
        )
    }

    private func snapshot(
        cid: String = "image001.png@outlook", filename: String = "image001.png",
        width: Int16, height: Int16, state: Attachment.State
    ) -> MessageBubbleAttachmentSnapshot {
        .init(contentId: cid, filename: filename, mimeType: "image/png", stateRaw: state.rawValue,
              localURL: nil, byteSize: 50_000, pageCount: 0, width: width, height: height)
    }
}
