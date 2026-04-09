import XCTest
@testable import esc_chatmail

@MainActor
final class MessageFormatBuilderTests: XCTestCase {

    var sut: MessageFormatBuilder!
    var authSession: AuthSession!

    override func setUp() {
        super.setUp()
        authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "MessageFormatBuilderTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = "test@example.com"
        authSession.userName = "Test User"
        sut = MessageFormatBuilder(authSession: authSession)
    }

    override func tearDown() {
        sut = nil
        authSession = nil
        super.tearDown()
    }

    func testFormatForwardedMessage_buildsForwardHeaderFromValueSnapshot() {
        let result = sut.formatForwardedMessage(
            .init(
                id: "forward-source-message",
                subject: "Quarterly Update",
                internalDate: Date(timeIntervalSince1970: 1_704_326_400),
                isFromMe: false,
                bodyText: "Original message body",
                snippet: nil,
                originalHTML: "<html><body><p>Original HTML body</p></body></html>",
                participants: [
                    .init(email: "test@example.com", displayName: "Test User"),
                    .init(email: "friend@example.com", displayName: "Friend")
                ]
            )
        )

        XCTAssertEqual(result.subject, "Fwd: Quarterly Update")
        XCTAssertTrue(result.body.contains("---------- Forwarded message ---------"))
        XCTAssertTrue(result.body.contains("From: Friend"))
        XCTAssertTrue(result.body.contains("Subject: Quarterly Update"))
        XCTAssertTrue(result.body.contains("To: friend@example.com"))
        XCTAssertTrue(result.body.contains("Original message body"))
        XCTAssertTrue(result.htmlBody?.contains("Original HTML body") == true)
    }

    // MARK: - buildFinalHTMLForForward Tests

    func testBuildFinalHTMLForForward_withUserContent_prependsToHTML() {
        let userContent = "Hi there,\n\nPlease see the forwarded message below.\n\n---------- Forwarded message ---------\nOriginal content"
        let forwardedHTML = """
        <html>
        <body>
        <div>---------- Forwarded message ---------</div>
        <p>Original HTML content</p>
        </body>
        </html>
        """

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("Hi there"))
        XCTAssertTrue(result.contains("Please see the forwarded message below"))
        XCTAssertTrue(result.contains("Original HTML content"))
    }

    func testBuildFinalHTMLForForward_withoutUserContent_returnsOriginalHTML() {
        let userContent = "\n\n---------- Forwarded message ---------\nOriginal content"
        let forwardedHTML = """
        <html>
        <body>
        <div>---------- Forwarded message ---------</div>
        <p>Original HTML content</p>
        </body>
        </html>
        """

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertEqual(result, forwardedHTML)
    }

    func testBuildFinalHTMLForForward_userContentBeforeForwardHeader_extracted() {
        let userContent = "Check this out!\n\n---------- Forwarded message ---------\nForwarded content"
        let forwardedHTML = "<body><p>Forwarded</p></body>"

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("Check this out"))
        XCTAssertTrue(result.contains("<body>"))
    }

    // MARK: - generateHTMLFromPlainText Tests

    func testGenerateHTMLFromPlainText_preservesLineBreaks() {
        let plainText = "Line 1\nLine 2\nLine 3"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<br>"))
        XCTAssertTrue(result.contains("Line 1"))
        XCTAssertTrue(result.contains("Line 2"))
        XCTAssertTrue(result.contains("Line 3"))
    }

    func testGenerateHTMLFromPlainText_createsParagraphsForDoubleNewlines() {
        let plainText = "Paragraph 1\n\nParagraph 2\n\nParagraph 3"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<p"))
        XCTAssertTrue(result.contains("Paragraph 1"))
        XCTAssertTrue(result.contains("Paragraph 2"))
    }

    func testGenerateHTMLFromPlainText_includesProperHTMLStructure() {
        let plainText = "Simple text"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<!DOCTYPE html>"))
        XCTAssertTrue(result.contains("<html>"))
        XCTAssertTrue(result.contains("<head>"))
        XCTAssertTrue(result.contains("<meta charset=\"UTF-8\">"))
        XCTAssertTrue(result.contains("<body>"))
        XCTAssertTrue(result.contains("</html>"))
    }

    func testGenerateHTMLFromPlainText_escapesHTMLCharacters() {
        let plainText = "Test <script>alert('xss')</script> content"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertFalse(result.contains("<script>"))
        XCTAssertTrue(result.contains("&lt;script&gt;"))
    }

    func testGenerateHTMLFromPlainText_autoLinksHTTPURLs() {
        let plainText = "Visit https://example.com for more info"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<a href=\"https://example.com\""))
        XCTAssertTrue(result.contains("</a>"))
    }

    func testGenerateHTMLFromPlainText_autoLinksWWWURLs() {
        let plainText = "Visit www.example.com for more info"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<a href=\"https://www.example.com\""))
    }

    func testGenerateHTMLFromPlainText_preservesForwardedMessageHeader() {
        let plainText = """
        Hi,

        ---------- Forwarded message ---------
        From: Sender
        Date: Jan 1, 2026
        Subject: Test
        To: recipient@example.com

        Original message content here.
        """

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("---------- Forwarded message ---------"))
        XCTAssertTrue(result.contains("From: Sender"))
        XCTAssertTrue(result.contains("Original message content here"))
    }

    // MARK: - URL Auto-linking Tests

    func testAutoLinkURLs_multipleURLs_allLinked() {
        let plainText = "Check https://first.com and https://second.com"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("href=\"https://first.com\""))
        XCTAssertTrue(result.contains("href=\"https://second.com\""))
    }

    func testAutoLinkURLs_urlWithPath_preservesPath() {
        let plainText = "Visit https://example.com/path/to/page?query=value"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("https://example.com/path/to/page?query=value"))
    }

    func testAutoLinkURLs_httpURL_linked() {
        let plainText = "Insecure http://example.com link"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("href=\"http://example.com\""))
    }

    // MARK: - HTML Escaping Tests

    func testHTMLEscaping_ampersand_escaped() {
        let plainText = "Tom & Jerry"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("Tom &amp; Jerry"))
    }

    func testHTMLEscaping_angleBrackets_escaped() {
        let plainText = "Use <b> for bold"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("&lt;b&gt;"))
    }

    func testHTMLEscaping_quotes_escaped() {
        let plainText = "He said \"hello\" and 'goodbye'"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("&quot;hello&quot;"))
        XCTAssertTrue(result.contains("&#39;goodbye&#39;"))
    }

    // MARK: - Edge Cases

    func testBuildFinalHTMLForForward_noBodyTag_wrapsContent() {
        let userContent = "My message\n\n---------- Forwarded message ---------\nContent"
        let forwardedHTML = "<p>Just a paragraph without body tag</p>"

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("<body>"))
        XCTAssertTrue(result.contains("My message"))
        XCTAssertTrue(result.contains("Just a paragraph"))
    }

    func testGenerateHTMLFromPlainText_emptyString_generatesValidHTML() {
        let plainText = ""

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<!DOCTYPE html>"))
        XCTAssertTrue(result.contains("<body>"))
    }

    func testGenerateHTMLFromPlainText_whiteSpaceOnly_handled() {
        let plainText = "   \n\n   \n   "

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<body>"))
    }

    func testBuildFinalHTMLForForward_alternateForwardMarker_recognized() {
        let userContent = "My note\n\n----- Forwarded message -----\nOriginal"
        let forwardedHTML = "<body><p>HTML Content</p></body>"

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("My note"))
    }

    func testBuildFinalHTMLForForward_withoutForwardMarker_usesEntireUserContent() {
        let userContent = "My standalone note"
        let forwardedHTML = "<body><p>Forwarded HTML Content</p></body>"

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("My standalone note"))
        XCTAssertTrue(result.contains("Forwarded HTML Content"))
    }

    func testGenerateHTMLFromPlainText_longURL_linked() {
        let plainText = "Check https://web.birley.com/webmail/1113152/1637919743/88287ae9aea15923442fea56e-f1055a388656f3c900f8d513b77b4a059863835"

        let result = sut.generateHTMLFromPlainText(plainText)

        XCTAssertTrue(result.contains("<a href=\"https://web.birley.com/webmail/"))
    }
}
