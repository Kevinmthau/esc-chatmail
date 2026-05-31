import XCTest
@testable import esc_chatmail

final class ParsedEmailProviderTests: XCTestCase {
    func testProviderParsesSameSourceSignatureOnceForMultipleDerivedValues() async throws {
        let provider = ParsedEmailProvider()
        let html = """
        <html>
        <body>
          <h1>Weekly update</h1>
          <p>Hello world.</p>
          <img src="cid:Hero-Image">
          <table><tr><td><a href="https://example.com">Open</a></td></tr></table>
        </body>
        </html>
        """

        let first = await provider.parsedEmail(
            messageId: "message-1",
            sourceSignature: "sha256:first",
            canonicalHTML: html
        )
        let parsed = try XCTUnwrap(first)

        XCTAssertEqual(parsed.plainText, "Weekly update\n\nHello world.\n\nOpen")
        XCTAssertEqual(parsed.referencedInlineContentIDs, ["hero-image"])
        XCTAssertEqual(parsed.htmlMetrics.imageCount, 1)
        XCTAssertEqual(parsed.htmlMetrics.tableCount, 1)
        XCTAssertEqual(parsed.htmlMetrics.linkCount, 1)
        XCTAssertEqual(parsed.htmlSummary.h1Text, "Weekly update")

        let second = await provider.parsedEmail(
            messageId: "message-1",
            sourceSignature: "sha256:first",
            canonicalHTML: html
        )

        let unwrappedSecond = try XCTUnwrap(second)
        XCTAssertTrue(parsed === unwrappedSecond)
        let parseAttemptCount = await provider.debugParseAttemptCount()
        XCTAssertEqual(parseAttemptCount, 1)
    }

    func testProviderInvalidatesMessageEntryWhenSourceSignatureChanges() async throws {
        let provider = ParsedEmailProvider()
        let html = "<p>Hello world.</p>"

        let first = await provider.parsedEmail(
            messageId: "message-1",
            sourceSignature: "sha256:first",
            canonicalHTML: html
        )
        XCTAssertNotNil(first)

        let second = await provider.parsedEmail(
            messageId: "message-1",
            sourceSignature: "sha256:second",
            canonicalHTML: html
        )
        XCTAssertNotNil(second)
        let unwrappedFirst = try XCTUnwrap(first)
        let unwrappedSecond = try XCTUnwrap(second)
        XCTAssertFalse(unwrappedFirst === unwrappedSecond)
        let cachedCount = await provider.debugCachedCount()
        let parseAttemptCountAfterSecondSignature = await provider.debugParseAttemptCount()
        XCTAssertEqual(cachedCount, 1)
        XCTAssertEqual(parseAttemptCountAfterSecondSignature, 2)

        let reloadedFirst = await provider.parsedEmail(
            messageId: "message-1",
            sourceSignature: "sha256:first",
            canonicalHTML: html
        )
        XCTAssertNotNil(reloadedFirst)
        let parseAttemptCountAfterReload = await provider.debugParseAttemptCount()
        XCTAssertEqual(parseAttemptCountAfterReload, 3)
    }

    func testProviderParseFailureReturnsNilAndRecordsFailure() async {
        struct ParserFailure: Error {}

        let provider = ParsedEmailProvider(parser: { _ in
            throw ParserFailure()
        })

        let parsed = await provider.parsedEmail(
            messageId: "message-1",
            sourceSignature: "sha256:broken",
            canonicalHTML: "<p>Broken</p>"
        )

        XCTAssertNil(parsed)
        let parseAttemptCount = await provider.debugParseAttemptCount()
        let parseFailureCount = await provider.debugParseFailureCount()
        XCTAssertEqual(parseAttemptCount, 1)
        XCTAssertEqual(parseFailureCount, 1)
    }

    func testRenderQualityEvaluatorMatchesFallbackPathWithParsedEmail() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>.primaryCTA { display: none; }</style>
        </head>
        <body>
          <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png"></td></tr></table>
          <table width="100%"><tr><td height="64">&nbsp;</td></tr></table>
          <table width="100%"><tr><td>Please verify your login in the mobile app.</td></tr></table>
          <table class="primaryCTA" width="100%"><tr><td><a href="https://example.com/verify">Verify now</a></td></tr></table>
          <table width="100%"><tr><td>Security Center | Privacy Policy</td></tr></table>
        </body>
        </html>
        """
        let plainText = """
        Example Bank security alert

        Verify your login to continue.
        Use this verification code: 482913
        https://example.com/verify
        """
        let evaluator = EmailRenderQualityEvaluator()
        let parsed = try XCTUnwrap(try ParsedEmail.parse(
            messageId: "message-1",
            sourceSignature: "sha256:quality",
            canonicalHTML: html
        ))

        let fallbackPath = evaluator.evaluate(
            html: html,
            plainText: plainText,
            senderEmail: "security@examplebank.com",
            subject: "Verify your login"
        )
        let parsedPath = evaluator.evaluate(
            parsedEmail: parsed,
            html: html,
            plainText: plainText,
            senderEmail: "security@examplebank.com",
            subject: "Verify your login"
        )

        XCTAssertEqual(parsedPath.presentation, fallbackPath.presentation)
        XCTAssertEqual(parsedPath.fallbackText, fallbackPath.fallbackText)
        XCTAssertEqual(parsedPath.summary, fallbackPath.summary)
    }

    func testBubbleAnalysisUsesParsedEmailInlineContentIDsWithoutChangingBehavior() throws {
        let html = """
        <html>
        <body>
          <picture>
            <source srcset="cid:hero-image 1x, cid:hero-image-2x 2x">
            <img src="cid:fallback-image" alt="Hero image">
          </picture>
        </body>
        </html>
        """
        let parsed = try XCTUnwrap(try ParsedEmail.parse(
            messageId: "message-1",
            sourceSignature: "sha256:inline",
            canonicalHTML: html
        ))

        let parsedAnalysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            parsedEmail: parsed,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: nil,
            senderName: nil,
            senderEmail: nil,
            subject: nil,
            attachmentSnapshots: []
        )
        let fallbackAnalysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: nil,
            senderName: nil,
            senderEmail: nil,
            subject: nil,
            attachmentSnapshots: []
        )

        XCTAssertEqual(parsedAnalysis, fallbackAnalysis)
        XCTAssertEqual(parsedAnalysis.referencedInlineContentIDs, [
            "fallback-image",
            "hero-image",
            "hero-image-2x"
        ])
    }

    func testPreviewClassifierMatchesFallbackPathWithParsedEmail() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <p><a href="https://example.com/view">View in browser</a></p>
            <table><tr><td><img src="https://cdn.example.com/hero.jpg"></td></tr></table>
            <table><tr><td><img src="https://cdn.example.com/chart-1.jpg"></td></tr></table>
            <table><tr><td><img src="https://cdn.example.com/chart-2.jpg"></td></tr></table>
            <table><tr><td><img src="https://cdn.example.com/chart-3.jpg"></td></tr></table>
            <p><a href="https://example.com/story-1">Story one</a></p>
            <p><a href="https://example.com/story-2">Story two</a></p>
            <p><a href="https://example.com/story-3">Story three</a></p>
            <p><a href="https://example.com/story-4">Story four</a></p>
            <p><a href="https://example.com/story-5">Story five</a></p>
            <p><a href="https://example.com/story-6">Story six</a></p>
            <p><a href="https://example.com/story-7">Story seven</a></p>
            <p><a href="https://example.com/story-8">Story eight</a></p>
            <p><a href="https://example.com/story-9">Story nine</a></p>
            <p><a href="https://example.com/story-10">Story ten</a></p>
            <p><a href="https://example.com/story-11">Story eleven</a></p>
            <p>Manage preferences or unsubscribe at any time.</p>
        </body>
        </html>
        """
        let parsed = try XCTUnwrap(try ParsedEmail.parse(
            messageId: "message-1",
            sourceSignature: "sha256:classifier",
            canonicalHTML: html
        ))
        let classifier = EmailPreviewClassifier()

        let fallbackPath = classifier.classify(
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@morningbrew.com",
            subject: "Daily Brief"
        )
        let parsedPath = classifier.classify(
            parsedEmail: parsed,
            canonicalHTML: html,
            bodyText: nil,
            senderEmail: "newsletter@morningbrew.com",
            subject: "Daily Brief"
        )

        XCTAssertEqual(parsedPath, fallbackPath)
        XCTAssertEqual(parsedPath.kind, .newsletter)
    }
}
