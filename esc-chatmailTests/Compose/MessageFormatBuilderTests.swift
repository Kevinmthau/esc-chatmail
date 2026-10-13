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
                sender: .init(email: "friend@example.com", displayName: "Friend"),
                bodyText: "Original message body",
                snippet: nil,
                originalHTML: "<html><body><p>Original HTML body</p></body></html>",
                to: [.init(email: "test@example.com", displayName: "Test User")],
                cc: [.init(email: "team@example.com", displayName: "Team")]
            )
        )

        XCTAssertEqual(result.subject, "Fwd: Quarterly Update")
        XCTAssertTrue(result.body.contains("---------- Forwarded message ---------"))
        XCTAssertTrue(result.body.contains("From: Friend <friend@example.com>\n"))
        XCTAssertTrue(result.body.contains("Subject: Quarterly Update"))
        XCTAssertTrue(result.body.contains("To: Test User <test@example.com>\n"))
        XCTAssertTrue(result.body.contains("Cc: Team <team@example.com>\n"))
        XCTAssertTrue(result.body.contains("Original message body"))
        XCTAssertTrue(result.htmlBody?.contains("Original HTML body") == true)
        XCTAssertTrue(result.htmlBody?.contains("Friend &lt;friend@example.com&gt;") == true)
        XCTAssertTrue(result.htmlBody?.contains("<strong>Cc:</strong> Team &lt;team@example.com&gt;") == true)
    }

    func testFormatForwardedMessage_preservesSenderAliasAndQuotedRecipientName() {
        let source = MessageFormatBuilder.ForwardSource(
            id: "sent-with-alias",
            subject: "Plans",
            internalDate: Date(timeIntervalSince1970: 1_704_326_400),
            sender: .init(email: "alias@example.com", displayName: "Alias Sender"),
            bodyText: "Original message body",
            snippet: nil,
            originalHTML: nil,
            to: [.init(email: "test@example.com", displayName: "Doe, Jane")],
            cc: []
        )
        authSession.userEmail = "different-account@example.com"

        let result = sut.formatForwardedMessage(source)

        XCTAssertTrue(result.body.contains("From: Alias Sender <alias@example.com>\n"))
        XCTAssertTrue(result.body.contains("To: \"Doe, Jane\" <test@example.com>\n"))
        XCTAssertFalse(result.body.contains("different-account@example.com"))
        XCTAssertEqual(
            ForwardedMessageDisplayParser.parseForward(from: result.body)?.recipientSummary,
            "Doe, Jane"
        )
    }

    func testFormatForwardedMessage_preservesLiteralHTMLEntitiesInPlainBody() {
        let body = "Use &lt;code&gt; and &amp; literally, including &#39;quoted&#39;."
        let result = sut.formatForwardedMessage(makePlainSource(bodyText: body))

        XCTAssertTrue(result.body.hasSuffix(body))
    }

    func testFormatForwardedMessage_blankBodyFallsBackToSnippet() {
        let result = sut.formatForwardedMessage(
            makePlainSource(bodyText: " \n\t ", snippet: "Available message snippet")
        )

        XCTAssertTrue(result.body.hasSuffix("Available message snippet"))
    }

    func testFormatForwardedMessage_rawHeadersPreserveEmptyGroupsInPlainTextAndHTML() {
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Original body",
            originalHTML: "<body><p>Original body</p></body>",
            rawToHeader: "undisclosed-recipients:;",
            rawCcHeader: "Private Team:;"
        ))

        XCTAssertTrue(result.body.contains("To: undisclosed-recipients:;\n"))
        XCTAssertTrue(result.body.contains("Cc: Private Team:;\n"))
        XCTAssertTrue(result.htmlBody?.contains("<strong>To:</strong> undisclosed-recipients:;") == true)
        XCTAssertTrue(result.htmlBody?.contains("<strong>Cc:</strong> Private Team:;") == true)
    }

    func testFormatForwardedMessage_explicitEmptyRawHeaderOverridesLegacyParticipants() {
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Original body",
            to: [.init(email: "stale@example.com", displayName: "Stale")],
            rawToHeader: ""
        ))

        XCTAssertFalse(result.body.contains("\nTo:"))
        XCTAssertFalse(result.body.contains("stale@example.com"))
    }

    func testFormatForwardedMessage_rawHeadersPreserveNamedGroupsAndMailboxOrder() {
        let to = "Team: Alice <alice@example.com>, Bob <bob@example.com>;"
        let cc = "First: first@example.com;, Solo <solo@example.com>, Second: second@example.com;"
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Original body",
            rawToHeader: to,
            rawCcHeader: cc
        ))

        XCTAssertTrue(result.body.contains("To: \(to)\n"))
        XCTAssertTrue(result.body.contains("Cc: \(cc)\n"))
    }

    func testFormatForwardedMessage_rawGroupNamesDecodeAfterStructuralDelimiters() {
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Original body",
            originalHTML: "<body>Original body</body>",
            rawToHeader: "=?utf-8?Q?Team=3A_West=2C_Unit?=: =?utf-8?Q?Doe=2C_Jane=3B_Sr?= <jane@example.com>;"
        ))

        XCTAssertTrue(result.body.contains("To: \"Team: West, Unit\": \"Doe, Jane; Sr\" <jane@example.com>;\n"))
        XCTAssertTrue(result.htmlBody?.contains("&quot;Team: West, Unit&quot;: &quot;Doe, Jane; Sr&quot; &lt;jane@example.com&gt;;") == true)
    }

    func testFormatForwardedMessage_rawEncodedWordsKeepLiteralDelimitersInsideNames() {
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Original body",
            rawToHeader: "=?utf-8?Q?Team:West;Operations?=: =?utf-8?Q?Doe,Jane?= <jane@example.com>;"
        ))

        XCTAssertTrue(result.body.contains("To: \"Team:West;Operations\": \"Doe,Jane\" <jane@example.com>;\n"))
    }

    func testFormatForwardedMessage_rawGroupsPreserveQuotedLocalPartsCommentsAndDomainLiterals() {
        let to = "Team: =?utf-8?Q?Doe=2C_Jane?= <\"a:b;c,d\"@example.com>, \"e:f;g,h\"@example.com;"
        let cc = "\"Team:West;Unit\": Alice (West (Unit:1); A,B) <alice@example.com>, local@[IPv6:2001:db8::1];"
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Original body",
            rawToHeader: to,
            rawCcHeader: cc
        ))

        XCTAssertTrue(result.body.contains("To: Team: \"Doe, Jane\" <\"a:b;c,d\"@example.com>, \"e:f;g,h\"@example.com;\n"))
        XCTAssertTrue(result.body.contains("Cc: \(cc)\n"))
    }

    func testFormatForwardedMessage_unparseableRawRecipientSpansRemainPresent() {
        let to = "Team: unknown recipient, valid@example.com;, unresolved"
        let result = sut.formatForwardedMessage(makePlainSource(bodyText: "Body", rawToHeader: to))

        XCTAssertTrue(result.body.contains("To: \(to)\n"))
    }

    func testFormatForwardedMessage_decodedMailboxNamePreservesTrailingComment() {
        let result = sut.formatForwardedMessage(makePlainSource(
            bodyText: "Body",
            rawToHeader: "Team: =?utf-8?Q?Doe=2C_Jane?= <jane@example.com> (Original recipient);",
            rawCcHeader: "jane@example.com (=?utf-8?Q?Doe=2C_Jane?=)"
        ))

        XCTAssertTrue(result.body.contains("To: Team: \"Doe, Jane\" <jane@example.com> (Original recipient);\n"))
        XCTAssertTrue(result.body.contains("Cc: jane@example.com (=?utf-8?Q?Doe=2C_Jane?=)\n"))
    }

    func testFormatForwardedMessage_complexEncodedNamesPreserveRawAddressesAndComments() {
        let to = "=?utf-8?Q?Alice?= (old <old@example.com>) <alice@example.com>"
        let cc = "\"=?utf-8?Q?Alice?= <old@example.com>\" <alice@example.com>"
        let result = sut.formatForwardedMessage(makePlainSource(bodyText: "Body", rawToHeader: to, rawCcHeader: cc))

        XCTAssertTrue(result.body.contains("To: \(to)\n"))
        XCTAssertTrue(result.body.contains("Cc: \(cc)\n"))
    }

    func testFormatForwardedMessage_encodedGroupNameWithCommentRemainsVerbatim() {
        let to = "=?utf-8?Q?Team?= (original group): alice@example.com;"
        let result = sut.formatForwardedMessage(makePlainSource(bodyText: "Body", rawToHeader: to))

        XCTAssertTrue(result.body.contains("To: \(to)\n"))
    }

    // MARK: - buildFinalHTMLForForward Tests

    func testBuildFinalHTMLForForward_withUserContent_prependsToHTML() {
        let userContent = "Hi there,\n\nPlease see the forwarded message below."
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
        let userContent = " \n\t "
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

    func testBuildFinalHTMLForForward_forwardMarkerInUserNote_preservesEntireNote() {
        let userContent = "Check this out!\n\n---------- Forwarded message ---------\nThis is still part of my note."
        let forwardedHTML = "<body><p>Forwarded</p></body>"

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("Check this out"))
        XCTAssertTrue(result.contains("---------- Forwarded message ---------"))
        XCTAssertTrue(result.contains("This is still part of my note."))
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

    func testAutoLinkURLs_queryParametersWithAmpersands_preservesEntireLink() {
        let result = sut.generateHTMLFromPlainText(
            "Visit https://example.com/review?document=123&token=abc&mode=full then reply."
        )

        XCTAssertTrue(result.contains("href=\"https://example.com/review?document=123&amp;token=abc&amp;mode=full\""))
        XCTAssertTrue(result.contains(">https://example.com/review?document=123&amp;token=abc&amp;mode=full</a> then reply."))
    }

    func testAutoLinkURLs_queryParametersEscapeHTMLAndSurroundingText() {
        let result = sut.generateHTMLFromPlainText(
            "<review> www.example.com/review?a=1&b=2 & reply \"yes\""
        )

        XCTAssertTrue(result.contains("&lt;review&gt; <a href=\"https://www.example.com/review?a=1&amp;b=2\""))
        XCTAssertTrue(result.contains("</a> &amp; reply &quot;yes&quot;"))
        XCTAssertFalse(result.contains("&amp;amp;"))
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
        let userContent = "My message"
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

    func testBuildFinalHTMLForForward_alternateForwardMarkerInNote_preservesEntireNote() {
        let userContent = "My note\n\n----- Forwarded message -----\nOriginal"
        let forwardedHTML = "<body><p>HTML Content</p></body>"

        let result = sut.buildFinalHTMLForForward(userContent: userContent, forwardedHTML: forwardedHTML)

        XCTAssertTrue(result.contains("My note"))
        XCTAssertTrue(result.contains("----- Forwarded message -----"))
        XCTAssertTrue(result.contains("Original"))
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

    private func makePlainSource(
        bodyText: String?,
        snippet: String? = nil,
        originalHTML: String? = nil,
        to: [MessageFormatBuilder.ForwardSource.Participant] = [],
        rawToHeader: String? = nil,
        rawCcHeader: String? = nil
    ) -> MessageFormatBuilder.ForwardSource {
        .init(
            id: "plain-forward",
            subject: "Plain message",
            internalDate: Date(timeIntervalSince1970: 1_704_326_400),
            sender: .init(email: "sender@example.com", displayName: nil),
            bodyText: bodyText,
            snippet: snippet,
            originalHTML: originalHTML,
            to: to,
            cc: [],
            rawToHeader: rawToHeader,
            rawCcHeader: rawCcHeader
        )
    }
}
