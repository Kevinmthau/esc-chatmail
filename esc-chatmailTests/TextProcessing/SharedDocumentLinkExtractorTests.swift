import XCTest
@testable import esc_chatmail

final class SharedDocumentLinkExtractorTests: XCTestCase {
    func testExtract_googleSheetsLinks_areReturnedAsSharedDocumentLinks() {
        let text = """
        Brynn:
        https://docs.google.com/spreadsheets/d/620890317158893082/edit?usp=sharing&ouid=111

        Kevin:
        https://docs.google.com/spreadsheets/d/620890317158893083/edit?usp=sharing&ouid=222
        """

        let links = SharedDocumentLinkExtractor.extract(from: [text])

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].kind, .googleSheet)
        XCTAssertEqual(links[1].kind, .googleSheet)
        XCTAssertEqual(links[0].url.host, "docs.google.com")
        XCTAssertEqual(links[1].url.host, "docs.google.com")
    }

    func testExtract_dedupesSameGoogleResourceWithDifferentQueryParameters() {
        let text = """
        https://docs.google.com/spreadsheets/d/abc123456/edit?usp=sharing
        https://docs.google.com/spreadsheets/d/abc123456/edit?usp=drive_link&resourcekey=xyz
        """

        let links = SharedDocumentLinkExtractor.extract(from: [text])

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.kind, .googleSheet)
    }

    func testExtract_filtersOutNonGoogleWorkspaceLinks() {
        let text = """
        https://example.com/report
        https://www.nytimes.com/
        """

        let links = SharedDocumentLinkExtractor.extract(from: [text])

        XCTAssertTrue(links.isEmpty)
    }

    func testExtract_respectsOrderAndMaxCountAcrossMessageCandidates() {
        let first = "Doc: https://docs.google.com/document/d/doc123/edit"
        let second = "Slides: https://docs.google.com/presentation/d/slides123/edit"
        let third = "Sheet: https://docs.google.com/spreadsheets/d/sheet123/edit"

        let links = SharedDocumentLinkExtractor.extract(
            from: [first, second, third],
            maxCount: 2
        )

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].kind, .googleDoc)
        XCTAssertEqual(links[1].kind, .googleSlides)
    }

    func testExtract_driveFolderIsDetected() {
        let text = "Folder: https://drive.google.com/drive/folders/1f0lderAbC123?usp=sharing"

        let links = SharedDocumentLinkExtractor.extract(from: [text])

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].kind, .googleDriveFolder)
    }

    func testRemovingLinks_removesSharedDocumentURLsAndKeepsSurroundingText() {
        let text = """
        Daily special overview.
        https://docs.google.com/document/d/doc123/edit?usp=sharing

        MOTD not yet tackled.
        """
        let links = SharedDocumentLinkExtractor.extract(from: [text])

        let cleaned = SharedDocumentLinkExtractor.removingLinks(from: text, matching: links)

        XCTAssertEqual(cleaned, "Daily special overview.\n\nMOTD not yet tackled.")
    }

    func testRemovingLinks_returnsNilWhenMessageContainsOnlySharedDocumentURLs() {
        let text = """
        https://docs.google.com/document/d/doc123/edit
        https://docs.google.com/spreadsheets/d/sheet123/edit
        """
        let links = SharedDocumentLinkExtractor.extract(from: [text])

        let cleaned = SharedDocumentLinkExtractor.removingLinks(from: text, matching: links)

        XCTAssertNil(cleaned)
    }
}
