import XCTest
@testable import esc_chatmail

/// The preview pipeline works out once, off the main actor, what the snapshot path reads off a
/// preview's HTML: the digest its cache key embeds and the layout width its render scales to
/// (architecture review 2026-11, `web-content-rendering#4`, step 3). Built from them, the key is
/// byte-identical and the scale the same, and the card's task identity, evaluated at every body
/// evaluation, hashes nothing on the main actor.
@MainActor
final class EmailPreviewSnapshotDerivedValuesTests: XCTestCase {
    private let html = #"<html><body><table width="600"><tr><td>Newsletter</td></tr></table></body></html>"#

    func testDerivedValues_areWhatTheSnapshotPathComputes() {
        let payload = HTMLPreviewPayload(html: html, previewCacheKey: "preview-key")

        XCTAssertEqual(
            payload.derivedValues.contentFingerprint,
            EmailPreviewSnapshotCacheKey.contentFingerprint(for: html)
        )
        XCTAssertEqual(payload.derivedValues.estimatedLayoutWidth, HTMLPreviewScaleCalculator.estimatedLayoutWidth(from: html))
        XCTAssertEqual(payload.derivedValues.estimatedLayoutWidth, 600)
    }

    /// Revert-check: making `EmailPreviewSnapshotViewModel.cacheKey` hash `htmlContent` whatever
    /// it is given fails this.
    func testCacheKey_fromDerivedValues_isByteIdentical_andHashesNothingOnTheMainThread() {
        let derived = HTMLPreviewDerivedValues(html: html)
        let before = EmailPreviewSnapshotCacheKey.mainThreadComputationCountForTesting

        let key = EmailPreviewSnapshotViewModel.cacheKey(
            previewCacheKey: "preview-key",
            htmlContent: html,
            derivedValues: derived,
            containerWidth: 300,
            isDarkMode: true
        )

        XCTAssertEqual(EmailPreviewSnapshotCacheKey.mainThreadComputationCountForTesting - before, 0)
        XCTAssertEqual(
            key,
            EmailPreviewSnapshotCacheKey.make(
                previewCacheKey: "preview-key",
                renderedHTML: html,
                containerWidth: 300,
                isDarkMode: true
            )
        )

        let withoutDerived = EmailPreviewSnapshotCacheKey.mainThreadComputationCountForTesting
        _ = EmailPreviewSnapshotViewModel.cacheKey(
            previewCacheKey: "preview-key",
            htmlContent: html,
            derivedValues: nil,
            containerWidth: 300,
            isDarkMode: true
        )
        XCTAssertEqual(
            EmailPreviewSnapshotCacheKey.mainThreadComputationCountForTesting - withoutDerived,
            1,
            "Control: without them the key hashes the HTML here"
        )
    }

    /// The render scales by the pipeline's estimate, not by its own pass over the HTML: here the
    /// HTML names no width and the estimate does.
    ///
    /// Revert-check: making `EmailPreviewSnapshotRenderSession.init` ignore `derivedValues` fails
    /// this.
    func testRenderSession_scalesByThePipelinesEstimate() throws {
        let session = try EmailPreviewSnapshotRenderSession(
            request: EmailPreviewSnapshotRequest(
                html: "<html><body><p>No width named</p></body></html>",
                cacheKey: "derived-scale-\(UUID().uuidString)",
                containerWidth: 280,
                isDarkMode: false,
                senderEmail: nil,
                message: nil,
                derivedValues: HTMLPreviewDerivedValues(html: html)
            )
        )

        XCTAssertEqual(
            session.scaleForTesting,
            HTMLPreviewScaleCalculator.previewScale(defaultScale: 0.5, containerWidth: 280, estimatedLayoutWidth: 600)
        )
        XCTAssertNotEqual(session.scaleForTesting, 0.5, "Precondition: the estimate changes the scale")
    }

    /// The row hands the payload's values to its card.
    ///
    /// Revert-check: dropping `derivedValues: payload.derivedValues` from `EmailContentSection`
    /// fails this.
    func testEmailContentSection_passesThePayloadsDerivedValues() throws {
        let source = try repositorySource("esc-chatmail/Views/Components/EmailContent/EmailContentSection.swift")
        XCTAssertTrue(source.contains("derivedValues: payload.derivedValues"))
    }
}
