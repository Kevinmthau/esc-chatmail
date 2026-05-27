import XCTest
@testable import esc_chatmail

final class EmailDOMHTMLSanitizerTests: XCTestCase {

    func testRemoveDangerousElements_removesConfiguredSubtrees() throws {
        let html = """
        <p>Safe before</p>
        <script>alert('xss')</script>
        <iframe src="https://evil.example/phish"></iframe>
        <form action="https://evil.example/steal"><input name="password"></form>
        <meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel="stylesheet" href="https://evil.example/steal.css">
        <object data="malware.swf"><embed src="malware.swf"></object>
        <p>Safe after</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<script"))
        XCTAssertFalse(lowercasedResult.contains("alert('xss')"))
        XCTAssertFalse(lowercasedResult.contains("<iframe"))
        XCTAssertFalse(lowercasedResult.contains("<form"))
        XCTAssertFalse(lowercasedResult.contains("<input"))
        XCTAssertFalse(lowercasedResult.contains("<meta"))
        XCTAssertFalse(lowercasedResult.contains("<link"))
        XCTAssertFalse(lowercasedResult.contains("<object"))
        XCTAssertFalse(lowercasedResult.contains("<embed"))
        XCTAssertFalse(lowercasedResult.contains("evil.example"))
        XCTAssertFalse(lowercasedResult.contains("malware.swf"))
        XCTAssertTrue(result.contains("<p>Safe before</p>"))
        XCTAssertTrue(result.contains("<p>Safe after</p>"))
    }

    func testRemoveEventHandlers_preservesCloudflareImageDirectiveInURLPath() throws {
        let html = """
        <img src="https://content.example/cdn-cgi/image/onerror=redirect,width=650,dpr=2,format=auto/photo.jpeg" onerror="alert('xss')" alt="Photo">
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertTrue(result.contains("onerror=redirect,width=650"))
        XCTAssertTrue(result.contains("alt=\"Photo\""))
        XCTAssertFalse(result.contains(" onerror="))
        XCTAssertFalse(result.contains("alert('xss')"))
    }

    func testRemoveEventHandlers_removesEveryAttributeStartingWithOn() throws {
        let html = """
        <div onclick="steal()" ONMOUSEOVER="track()" one="also-event-like" data-on="keep">Body</div>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.contains("onclick"))
        XCTAssertFalse(result.contains("ONMOUSEOVER"))
        XCTAssertFalse(result.contains("one="))
        XCTAssertFalse(result.contains("steal()"))
        XCTAssertFalse(result.contains("track()"))
        XCTAssertTrue(result.contains("data-on=\"keep\""))
        XCTAssertTrue(result.contains(">Body</div>"))
    }

    func testStyleTags_preserved() throws {
        let html = """
        <style>
        body { background: red; }
        @media (max-width: 600px) { .content { width: 100%; } }
        </style>
        <p>Content</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertTrue(result.contains("<style>"))
        XCTAssertTrue(result.contains("@media"))
        XCTAssertTrue(result.contains(".content"))
        XCTAssertTrue(result.contains("<p>Content</p>"))
    }

    func testSafeLayoutAndEmailAttributes_preserved() throws {
        let html = """
        <table id="container" class="layout" role="presentation" data-template="receipt" aria-label="Receipt" width="600" cellpadding="0" cellspacing="0" border="0" style="width: 100%">
          <tr><td align="center" valign="top" bgcolor="#ffffff">
            <img src="https://example.com/logo.png" alt="Logo" width="120" height="40" data-cid="logo" aria-hidden="true" style="display: block">
          </td></tr>
        </table>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertTrue(result.contains("id=\"container\""))
        XCTAssertTrue(result.contains("class=\"layout\""))
        XCTAssertTrue(result.contains("role=\"presentation\""))
        XCTAssertTrue(result.contains("data-template=\"receipt\""))
        XCTAssertTrue(result.contains("aria-label=\"Receipt\""))
        XCTAssertTrue(result.contains("width=\"600\""))
        XCTAssertTrue(result.contains("cellpadding=\"0\""))
        XCTAssertTrue(result.contains("cellspacing=\"0\""))
        XCTAssertTrue(result.contains("style=\"width: 100%\""))
        XCTAssertTrue(result.contains("align=\"center\""))
        XCTAssertTrue(result.contains("bgcolor=\"#ffffff\""))
        XCTAssertTrue(result.contains("src=\"https://example.com/logo.png\""))
        XCTAssertTrue(result.contains("data-cid=\"logo\""))
        XCTAssertTrue(result.contains("aria-hidden=\"true\""))
    }

    func testStandaloneTableRowFragment_preservesRowAndCellLayout() throws {
        let html = #"""
        <tr onclick="steal()">
          <td onmouseover="track()">Cell</td>
          <td><script>alert('xss')</script>Second</td>
        </tr>
        """#

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<html"))
        XCTAssertFalse(lowercasedResult.contains("<body"))
        XCTAssertTrue(lowercasedResult.contains("<tr"))
        XCTAssertTrue(result.contains("<td>Cell</td>"))
        XCTAssertTrue(result.contains("<td>Second</td>"))
        XCTAssertFalse(lowercasedResult.contains("onclick"))
        XCTAssertFalse(lowercasedResult.contains("onmouseover"))
        XCTAssertFalse(lowercasedResult.contains("<script"))
        XCTAssertFalse(result.contains("alert('xss')"))
    }

    func testStandaloneTableBodyFragment_preservesTableSectionLayout() throws {
        let html = """
        <tbody>
          <tr><td>Cell</td></tr>
        </tbody>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<html"))
        XCTAssertFalse(lowercasedResult.contains("<body"))
        XCTAssertTrue(lowercasedResult.contains("<tbody"))
        XCTAssertTrue(result.contains("<tr><td>Cell</td></tr>"))
    }

    func testSelfClosingDangerousTags_doNotRemoveFollowingSafeContent() throws {
        let html = """
        <p>Before</p><iframe src="https://evil.example/phish"/><p>After iframe</p><script src="bad.js"/><p>After script</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.lowercased().contains("<iframe"))
        XCTAssertFalse(result.lowercased().contains("<script"))
        XCTAssertFalse(result.contains("bad.js"))
        XCTAssertTrue(result.contains("<p>Before</p>"))
        XCTAssertTrue(result.contains("<p>After iframe</p>"))
        XCTAssertTrue(result.contains("<p>After script</p>"))
    }

    func testUnclosedDangerousTags_doNotRemoveFollowingSafeContent() throws {
        let html = """
        <p>Before</p><iframe src="https://evil.example/phish"><p>After iframe</p><form action="bad"><p>After form</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.lowercased().contains("<iframe"))
        XCTAssertFalse(result.lowercased().contains("<form"))
        XCTAssertTrue(result.contains("<p>Before</p>"))
        XCTAssertTrue(result.contains("<p>After iframe</p>"))
        XCTAssertTrue(result.contains("<p>After form</p>"))
    }

    func testUnclosedDangerousTagBeforeLaterSameNameTag_doesNotRemoveInterveningSafeContent() throws {
        let html = """
        <iframe src="https://evil.example/first"><p>Keep</p><iframe src="https://evil.example/second"></iframe><p>After iframe</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.lowercased().contains("<iframe"))
        XCTAssertFalse(result.contains("evil.example"))
        XCTAssertTrue(result.contains("<p>Keep</p>"))
        XCTAssertTrue(result.contains("<p>After iframe</p>"))
    }

    func testMalformedDangerousClosingTagName_doesNotRemoveFollowingSafeContent() throws {
        let html = """
        <p>Before</p><iframe src="https://evil.example/phish"><p>After iframe</p></iframefake><p>After fake close</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.lowercased().contains("<iframe"))
        XCTAssertTrue(result.contains("<p>Before</p>"))
        XCTAssertTrue(result.contains("<p>After iframe</p>"))
        XCTAssertTrue(result.contains("<p>After fake close</p>"))
    }

    func testDangerousClosingTagInsideComment_doesNotRemoveFollowingSafeContent() throws {
        let html = """
        <p>Before</p><iframe src="https://evil.example/phish"><!-- </iframe> --><p>After comment</p>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.lowercased().contains("<iframe"))
        XCTAssertTrue(result.contains("<p>Before</p>"))
        XCTAssertTrue(result.contains("<p>After comment</p>"))
    }

    func testPlainText_returnsUnchanged() throws {
        let text = "Hello, this is plain text without any HTML."

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: text)

        XCTAssertEqual(result, text)
    }

    func testPlainTextAngleBracketPlaceholder_returnsUnchanged() throws {
        let text = "Press <enter> to continue"

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: text)

        XCTAssertEqual(result, text)
    }

    func testPlainTextAngleBracketEmailAddress_returnsUnchanged() throws {
        let text = "Contact <alice@example.com> for details"

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: text)

        XCTAssertEqual(result, text)
    }

    func testUnknownTagWithAssignedAttribute_isTreatedAsHTML() throws {
        let html = #"<email-card data-template="receipt" onclick="steal()">Receipt body"#

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertTrue(result.contains(#"data-template="receipt""#))
        XCTAssertFalse(result.contains("onclick"))
        XCTAssertFalse(result.contains("steal()"))
        XCTAssertTrue(result.contains("Receipt body"))
    }

    func testFragmentInput_returnsFragmentWithoutDocumentWrappers() throws {
        let html = "<p>Hello</p><script>alert('xss')</script><p>World</p>"

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertFalse(result.lowercased().contains("<html"))
        XCTAssertFalse(result.lowercased().contains("<body"))
        XCTAssertTrue(result.contains("<p>Hello</p>"))
        XCTAssertTrue(result.contains("<p>World</p>"))
    }

    func testFragmentWithHeaderElement_returnsFragmentWithoutDocumentWrappers() throws {
        let html = #"""
        <header onclick="steal()"><p>Hello</p></header>
        <script>alert('xss')</script>
        <p>World</p>
        """#

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<html"))
        XCTAssertFalse(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains("<header>"))
        XCTAssertTrue(result.contains("<p>Hello</p>"))
        XCTAssertTrue(result.contains("<p>World</p>"))
        XCTAssertFalse(lowercasedResult.contains("onclick"))
        XCTAssertFalse(lowercasedResult.contains("<script"))
    }

    func testDocumentInput_returnsFullDocument() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Subject</title><script>alert('xss')</script></head>
        <body><p>Body</p></body>
        </html>
        """

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)

        XCTAssertTrue(result.contains("<!DOCTYPE"))
        XCTAssertTrue(result.lowercased().contains("<html"))
        XCTAssertTrue(result.lowercased().contains("<body"))
        XCTAssertTrue(result.contains("<title>Subject</title>"))
        XCTAssertTrue(result.contains("<p>Body</p>"))
        XCTAssertFalse(result.lowercased().contains("<script"))
    }

    func testBodyOnlyDocument_preservesBodyElementAndAttributes() throws {
        let html = #"""
        <body class="promo" style="margin:0" bgcolor="#f4f4f4" onload="steal()">
          <p>Offer</p>
          <script>alert('xss')</script>
        </body>
        """#

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(lowercasedResult.contains("<html"))
        XCTAssertTrue(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains(#"class="promo""#))
        XCTAssertTrue(result.contains(#"style="margin:0""#))
        XCTAssertTrue(result.contains("bgcolor=\"#f4f4f4\""))
        XCTAssertTrue(result.contains("<p>Offer</p>"))
        XCTAssertFalse(lowercasedResult.contains("onload"))
        XCTAssertFalse(lowercasedResult.contains("<script"))
        XCTAssertFalse(result.contains("alert('xss')"))
    }

    func testLateBodyDocument_preservesBodyElementAndAttributes() throws {
        let preheader = String(repeating: "Hidden preheader text. ", count: 120)
        let html = #"""
        <!-- \#(preheader) -->
        <body class="promo" style="margin:0" bgcolor="#f4f4f4" onload="steal()">
          <p>Offer</p>
          <script>alert('xss')</script>
        </body>
        """#
        let bodyRange = try XCTUnwrap(html.range(of: "<body"))
        XCTAssertGreaterThan(html.distance(from: html.startIndex, to: bodyRange.lowerBound), 2048)

        let result = try EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers(from: html)
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(lowercasedResult.contains("<html"))
        XCTAssertTrue(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains(#"class="promo""#))
        XCTAssertTrue(result.contains(#"style="margin:0""#))
        XCTAssertTrue(result.contains("bgcolor=\"#f4f4f4\""))
        XCTAssertTrue(result.contains("<p>Offer</p>"))
        XCTAssertFalse(lowercasedResult.contains("onload"))
        XCTAssertFalse(lowercasedResult.contains("<script"))
        XCTAssertFalse(result.contains("alert('xss')"))
    }
}

final class EmailDOMHTMLSanitizerParityTests: XCTestCase {
    private struct Case {
        let name: String
        let html: String
        let visibleSubstrings: [String]
        let hiddenSubstrings: [String]
    }

    private let parityCases: [Case] = [
        Case(
            name: "script and event handlers",
            html: """
            <p>Hello</p><a href="https://example.com" onclick="steal()">Link</a><script>alert('xss')</script><p>World</p>
            """,
            visibleSubstrings: ["Hello", "Link", "World"],
            hiddenSubstrings: ["<script", "alert('xss')", "onclick", "steal()"]
        ),
        Case(
            name: "Cloudflare path directive survives event stripping",
            html: """
            <img src="https://content.example/cdn-cgi/image/onerror=redirect,width=650,dpr=2,format=auto/photo.jpeg" onerror="alert('xss')" alt="Photo">
            """,
            visibleSubstrings: ["onerror=redirect,width=650", "alt=\"Photo\""],
            hiddenSubstrings: [" onerror=", "alert('xss')"]
        ),
        Case(
            name: "style tag and layout attributes survive",
            html: """
            <style>.content { width: 100%; }</style><table class="layout" width="600" cellpadding="0"><tr><td><p>Body</p></td></tr></table>
            """,
            visibleSubstrings: ["<style", ".content", "class=\"layout\"", "width=\"600\"", "cellpadding=\"0\"", "Body"],
            hiddenSubstrings: ["<script", "onclick"]
        ),
        Case(
            name: "specialized URL tracking and CSS sanitizers still run",
            html: #"""
            <p onclick="steal()">Body</p>
            <a href="java%73cript:alert('xss')">Bad link</a>
            <img src="cid:image001.png@01D12345.67890ABC" onerror="hack()" alt="Inline">
            <img src="https://tracking.example.com/open.gif" alt="Tracker">
            <style>
            .hero { background: url('javascript:alert(1)'); }
            @import url("https://evil.example/styles.css");
            </style>
            <p style="color: red; behavior: url(#default#time2);">Styled body</p>
            """#,
            visibleSubstrings: [
                "Body",
                "href=\"#\"",
                "cid:image001.png@01D12345.67890ABC",
                "alt=\"Inline\"",
                "<style",
                "color: red",
                "Styled body"
            ],
            hiddenSubstrings: [
                "onclick",
                "onerror",
                "java%73cript",
                "javascript:",
                "tracking.example.com",
                "alt=\"Tracker\"",
                "@import",
                "behavior:"
            ]
        )
    ]

    override func tearDown() {
        clearDOMSanitizerFlags()
        super.tearDown()
    }

    func testParity_securityOutcomesMatchAcrossLegacyAndDOMFirstPasses() {
        for parityCase in parityCases {
            let legacyResult = sanitizedWithDOMFlag(false, html: parityCase.html)
            let domResult = sanitizedWithDOMFlag(true, html: parityCase.html)

            for visibleSubstring in parityCase.visibleSubstrings {
                XCTAssertTrue(
                    legacyResult.contains(visibleSubstring),
                    "[\(parityCase.name)] legacy lost expected visible substring: \(visibleSubstring)\n\(legacyResult)"
                )
                XCTAssertTrue(
                    domResult.contains(visibleSubstring),
                    "[\(parityCase.name)] DOM lost expected visible substring: \(visibleSubstring)\n\(domResult)"
                )
            }

            for hiddenSubstring in parityCase.hiddenSubstrings {
                XCTAssertFalse(
                    legacyResult.contains(hiddenSubstring),
                    "[\(parityCase.name)] legacy leaked hidden substring: \(hiddenSubstring)\n\(legacyResult)"
                )
                XCTAssertFalse(
                    domResult.contains(hiddenSubstring),
                    "[\(parityCase.name)] DOM leaked hidden substring: \(hiddenSubstring)\n\(domResult)"
                )
            }
        }
    }

    func testFeatureFlag_specificFlagOrAllEnablesHTMLSanitization() {
        clearDOMSanitizerFlags()
        XCTAssertFalse(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        UserDefaults.standard.set(true, forKey: "EmailDOM_HTMLSanitization")
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        UserDefaults.standard.removeObject(forKey: "EmailDOM_HTMLSanitization")
        XCTAssertFalse(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        UserDefaults.standard.set(true, forKey: "EmailDOM_All")
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())
    }

    func testFeatureFlag_plainTextAngleBracketEmailAddressPreserved() {
        let text = "Contact <alice@example.com> for details"

        XCTAssertEqual(sanitizedWithDOMFlag(false, html: text), text)
        XCTAssertEqual(sanitizedWithDOMFlag(true, html: text), text)

        clearDOMSanitizerFlags()
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")
        XCTAssertEqual(
            HTMLSanitizerService.shared.sanitize(text, rewriteModernImageFormatHints: false),
            text
        )
    }

    func testFeatureFlag_allPreservesStandaloneTableRowFragment() {
        let html = #"<tr onclick="steal()"><td>Cell</td></tr>"#

        clearDOMSanitizerFlags()
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")

        let result = HTMLSanitizerService.shared.sanitize(
            html,
            rewriteModernImageFormatHints: false
        )
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<html"))
        XCTAssertFalse(lowercasedResult.contains("<body"))
        XCTAssertTrue(lowercasedResult.contains("<tr"))
        XCTAssertTrue(result.contains("<td>Cell</td>"))
        XCTAssertFalse(lowercasedResult.contains("onclick"))
    }

    func testFeatureFlag_bodyOnlyDocumentPreservesBodyAttributes() {
        let html = #"""
        <body class="promo" style="margin:0" bgcolor="#f4f4f4" onload="steal()">
          <p>Offer</p>
          <script>alert('xss')</script>
        </body>
        """#

        let result = sanitizedWithDOMFlag(true, html: html)
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains(#"class="promo""#))
        XCTAssertTrue(result.contains(#"style="margin:0""#))
        XCTAssertTrue(result.contains("bgcolor=\"#f4f4f4\""))
        XCTAssertTrue(result.contains("<p>Offer</p>"))
        XCTAssertFalse(lowercasedResult.contains("onload"))
        XCTAssertFalse(lowercasedResult.contains("<script"))
        XCTAssertFalse(result.contains("alert('xss')"))

        clearDOMSanitizerFlags()
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")

        let allFlagResult = HTMLSanitizerService.shared.sanitize(
            html,
            rewriteModernImageFormatHints: false
        )
        XCTAssertTrue(allFlagResult.lowercased().contains("<body"))
        XCTAssertTrue(allFlagResult.contains(#"class="promo""#))
        XCTAssertTrue(allFlagResult.contains(#"style="margin:0""#))
        XCTAssertTrue(allFlagResult.contains("bgcolor=\"#f4f4f4\""))
    }

    func testFeatureFlag_fullPipelineKeepsSpecializedSanitizersAfterDOMFirstPass() {
        let html = #"""
        <p onclick="steal()">Body</p>
        <a href="java%73cript:alert('xss')">Bad link</a>
        <img src="cid:image001.png@01D12345.67890ABC" onerror="hack()" alt="Inline">
        <img src="https://tracking.example.com/open.gif" alt="Tracker">
        <img src="https://content.example/cdn-cgi/image/width=650,format=auto/photo.jpeg" alt="Hero">
        <style>
        .hero { background: url('javascript:alert(1)'); }
        @import url("https://evil.example/styles.css");
        </style>
        <p style="color: red; behavior: url(#default#time2);">Styled body</p>
        """#

        assertFullSanitizationInvariants(
            sanitizedWithDOMFlag(false, html: html, rewriteModernImageFormatHints: true)
        )
        assertFullSanitizationInvariants(
            sanitizedWithDOMFlag(true, html: html, rewriteModernImageFormatHints: true)
        )

        clearDOMSanitizerFlags()
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")
        assertFullSanitizationInvariants(
            HTMLSanitizerService.shared.sanitize(html)
        )
    }

    private func assertFullSanitizationInvariants(
        _ result: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(result.contains("Body"), file: file, line: line)
        XCTAssertTrue(result.contains("Styled body"), file: file, line: line)
        XCTAssertTrue(result.contains("href=\"#\""), file: file, line: line)
        XCTAssertTrue(
            result.contains("cid:image001.png@01D12345.67890ABC"),
            file: file,
            line: line
        )
        XCTAssertTrue(result.contains("format=jpeg"), file: file, line: line)
        XCTAssertTrue(result.contains("alt=\"Hero\""), file: file, line: line)
        XCTAssertTrue(result.contains("<style"), file: file, line: line)
        XCTAssertTrue(result.contains("color: red"), file: file, line: line)

        XCTAssertFalse(lowercasedResult.contains("onclick"), file: file, line: line)
        XCTAssertFalse(lowercasedResult.contains("onerror"), file: file, line: line)
        XCTAssertFalse(lowercasedResult.contains("java%73cript"), file: file, line: line)
        XCTAssertFalse(lowercasedResult.contains("javascript:"), file: file, line: line)
        XCTAssertFalse(lowercasedResult.contains("tracking.example.com"), file: file, line: line)
        XCTAssertFalse(result.contains("alt=\"Tracker\""), file: file, line: line)
        XCTAssertFalse(lowercasedResult.contains("@import"), file: file, line: line)
        XCTAssertFalse(lowercasedResult.contains("behavior:"), file: file, line: line)
    }

    private func sanitizedWithDOMFlag(
        _ enabled: Bool,
        html: String,
        rewriteModernImageFormatHints: Bool = false
    ) -> String {
        clearDOMSanitizerFlags()
        UserDefaults.standard.set(enabled, forKey: "EmailDOM_HTMLSanitization")
        return HTMLSanitizerService.shared.sanitize(
            html,
            rewriteModernImageFormatHints: rewriteModernImageFormatHints
        )
    }

    private func clearDOMSanitizerFlags() {
        UserDefaults.standard.removeObject(forKey: "EmailDOM_HTMLSanitization")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_All")
    }
}
