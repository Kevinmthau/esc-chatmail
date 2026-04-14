import XCTest
@testable import esc_chatmail

final class GoogleDriveSharedFileMetadataProviderTests: XCTestCase {
    func testParseMetadata_prefersOpenGraphTitleAndImage() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc123",
            url: URL(string: "https://docs.google.com/document/d/doc123/edit?usp=sharing")!,
            kind: .googleDoc
        )
        let html = """
        <html>
        <head>
        <meta property="og:title" content="Omakase Update 260407 - Google Docs">
        <meta property="og:image" content="https://lh7-rt.googleusercontent.com/docsz/preview123">
        <title>Ignored Title</title>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Omakase Update 260407")
        XCTAssertEqual(
            metadata?.thumbnailURL,
            "https://lh7-rt.googleusercontent.com/docsz/preview123"
        )
    }

    func testParseMetadata_fallsBackToTitleTagAndThumbnailEndpoint() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleSlides|slides123",
            url: URL(string: "https://docs.google.com/presentation/d/slides123/edit")!,
            kind: .googleSlides
        )
        let html = """
        <html>
        <head>
        <title>Chop Chop Update 260408 - Google Slides</title>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Chop Chop Update 260408")
        XCTAssertEqual(
            metadata?.thumbnailURL,
            "https://drive.google.com/thumbnail?id=slides123&sz=w1600"
        )
    }

    func testParseMetadata_ignoresGenericSignInTitle() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleSheet|sheet123",
            url: URL(string: "https://docs.google.com/spreadsheets/d/sheet123/edit")!,
            kind: .googleSheet
        )
        let html = """
        <html>
        <head>
        <title>Sign in - Google Accounts</title>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Google Sheet")
        XCTAssertEqual(
            metadata?.thumbnailURL,
            "https://drive.google.com/thumbnail?id=sheet123&sz=w1600"
        )
    }

    func testParseMetadata_preservesApostrophesInDoubleQuotedMetaContent() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc456",
            url: URL(string: "https://docs.google.com/document/d/doc456/edit")!,
            kind: .googleDoc
        )
        let html = """
        <html>
        <head>
        <meta property="og:title" content="Today's plan - Google Docs">
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "Today's plan")
    }

    func testParseMetadata_preservesDoubleQuotesInSingleQuotedMetaContent() {
        let link = SharedDocumentLink(
            id: "SharedDocumentLink.Kind.googleDoc|doc789",
            url: URL(string: "https://docs.google.com/document/d/doc789/edit")!,
            kind: .googleDoc
        )
        let html = """
        <html>
        <head>
        <meta content='The "Launch" Plan - Google Docs' property='og:title'>
        </head>
        </html>
        """

        let metadata = GoogleDriveSharedFileMetadataProvider.parseMetadata(from: html, link: link)

        XCTAssertEqual(metadata?.title, "The \"Launch\" Plan")
    }
}
