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

    // MARK: - Links a row carries before its bubble load

    /// The cheap check stands in front of the data detector for every row of every window
    /// re-map, so it must pass every literally spelled link the extractor accepts: a row it
    /// rejects carries no links, shows the raw URL, and swaps to text plus a card when its load
    /// publishes.
    ///
    /// Revert-check: the search in `SharedDocumentLinkExtractor.mayContainLinks`. Narrowing
    /// the needle to one host (`docs.google.com`) fails the Drive fixtures, and dropping
    /// `.caseInsensitive` fails the upper-case host.
    func testMayContainLinks_isTrueForEveryLiterallySpelledLinkTheExtractorAccepts() {
        let texts = [
            "https://docs.google.com/spreadsheets/d/sheet1/edit",
            "https://docs.google.com/document/d/doc1/edit",
            "https://docs.google.com/presentation/d/deck1/edit",
            "https://docs.google.com/file/d/file1/view",
            "https://drive.google.com/drive/folders/folder1",
            "https://drive.google.com/file/d/file2/view",
            "https://drive.google.com/open?id=file3",
            "https://DOCS.GOOGLE.COM/document/d/doc2/edit",
            "no scheme: docs.google.com/document/d/doc3/edit"
        ]
        for text in texts {
            XCTAssertFalse(
                SharedDocumentLinkExtractor.extract(from: [text]).isEmpty,
                "Fixture must be a link the extractor accepts: \(text)"
            )
            XCTAssertTrue(SharedDocumentLinkExtractor.mayContainLinks(in: [nil, "", text]), text)
        }

        XCTAssertFalse(SharedDocumentLinkExtractor.mayContainLinks(in: []))
        XCTAssertFalse(
            SharedDocumentLinkExtractor.mayContainLinks(in: [nil, "", "plain text https://example.com/document/d/a"])
        )
    }

    /// The check is not a superset of the extractor, and this is the spelling it misses: a host
    /// Foundation resolves to `docs.google.com` without the text spelling it. Such a row
    /// carries no links before its load and gains its card when the load publishes, which is
    /// why the bubble takes the load's links once it has them
    /// (`MessageDisplayPolicy.sharedDocumentLinks`) instead of the row's throughout.
    ///
    /// HONEST SCOPE: pins a limitation, not a fix. If a Foundation release stops resolving
    /// these spellings the extractor assertions fail first, and the limitation (with the
    /// paragraph of `mayContainLinks`'s doc comment describing it) is gone.
    func testStoredRowLinks_hostSpelledOnlyAfterNormalization_isMissedAndLeftToTheLoad() {
        let texts = [
            "https://docs.%67oogle.com/document/d/encoded1/edit",
            "https://docs.\u{FF47}oogle.com/document/d/fullwidth1/edit",
            "https://docs.goo\u{00AD}gle.com/document/d/softhyphen1/edit"
        ]
        for text in texts {
            XCTAssertEqual(
                SharedDocumentLinkExtractor.bubbleLinks(preferredText: text, bodyText: nil, snippet: nil).map(\.kind),
                [.googleDoc],
                "Fixture must be a link the load publishes: \(text)"
            )
            XCTAssertFalse(SharedDocumentLinkExtractor.mayContainLinks(in: [text]), text)
            XCTAssertTrue(
                SharedDocumentLinkExtractor.storedRowLinks(
                    chatPreviewText: text,
                    bodyText: nil,
                    snippet: nil,
                    isForwardedEmail: false
                ).isEmpty,
                text
            )
        }
    }

    /// The order, trimming and limit the bubble's load has always used, now the one definition
    /// the row's own links share with it.
    ///
    /// Revert-check: in `SharedDocumentLinkExtractor.bubbleLinks`, reordering the candidates,
    /// or dropping `bodyText` or `snippet` from them, fails the order assertion; changing
    /// `bubbleLinkLimit` fails the cap.
    func testBubbleLinks_searchesPreferredTextThenBodyThenSnippet_cappedAtFour() {
        let links = SharedDocumentLinkExtractor.bubbleLinks(
            preferredText: "  Sheet: https://docs.google.com/spreadsheets/d/sheet1/edit \n",
            bodyText: "Doc: https://docs.google.com/document/d/doc1/edit and the sheet again "
                + "https://docs.google.com/spreadsheets/d/sheet1/edit?usp=sharing",
            snippet: "Slides: https://docs.google.com/presentation/d/deck1/edit"
        )
        XCTAssertEqual(links.map(\.id), ["googleSheet|sheet1", "googleDoc|doc1", "googleSlides|deck1"])

        let many = (1...6)
            .map { "https://docs.google.com/document/d/doc\($0)/edit" }
            .joined(separator: "\n")
        XCTAssertEqual(
            SharedDocumentLinkExtractor.bubbleLinks(preferredText: nil, bodyText: "   ", snippet: many).map(\.id),
            ["googleDoc|doc1", "googleDoc|doc2", "googleDoc|doc3", "googleDoc|doc4"]
        )
        XCTAssertEqual(SharedDocumentLinkExtractor.bubbleLinkLimit, 4)
    }

    /// Stored fields decide a row's links only where the load searches the stored preview
    /// first. A forward's load searches its parsed lead-in and neither body nor snippet; a
    /// blank-preview row's load searches text its compatibility path derives. Links computed
    /// from stored fields for either would not be the load's, so the row carries none.
    ///
    /// Revert-check: in `SharedDocumentLinkExtractor.storedRowMayCarryLinks`, dropping
    /// `!isForwardedEmail` fails the forwarded assertion and dropping the
    /// `MessagePreviewText.nonEmpty(chatPreviewText)` term fails the blank-preview ones.
    func testStoredRowLinks_forwardedOrBlankPreviewRow_carriesNone() {
        let linkText = "Plan: https://docs.google.com/document/d/doc1/edit"

        XCTAssertEqual(
            SharedDocumentLinkExtractor.storedRowLinks(
                chatPreviewText: "See the plan",
                bodyText: linkText,
                snippet: linkText,
                isForwardedEmail: false
            ).map(\.id),
            ["googleDoc|doc1"],
            "Control: the same fields on a row whose stored fields do decide its links"
        )
        XCTAssertTrue(
            SharedDocumentLinkExtractor.storedRowLinks(
                chatPreviewText: linkText,
                bodyText: linkText,
                snippet: linkText,
                isForwardedEmail: true
            ).isEmpty
        )
        for blankPreview in [nil, "", " \n\t "] {
            XCTAssertTrue(
                SharedDocumentLinkExtractor.storedRowLinks(
                    chatPreviewText: blankPreview,
                    bodyText: linkText,
                    snippet: linkText,
                    isForwardedEmail: false
                ).isEmpty,
                "preview: \(String(describing: blankPreview))"
            )
        }
    }
}
