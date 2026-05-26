import XCTest
@testable import esc_chatmail

final class EmailRenderQualityEvaluatorTests: XCTestCase {

    func testEvaluate_hiddenPrimaryCTAStyleRuleFallsBackToReadableText() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <style>
            .primaryCTA { display: none; }
          </style>
        </head>
        <body>
          <table width="100%"><tr><td align="center"><img src="https://example.com/logo.png" alt="Example Bank"></td></tr></table>
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

        let result = EmailRenderQualityEvaluator().evaluate(
            html: html,
            plainText: plainText,
            senderEmail: "security@examplebank.com",
            subject: "Verify your login"
        )

        XCTAssertEqual(result.presentation, .nativePlainText)
        XCTAssertTrue(result.fallbackText?.contains("Use this verification code: 482913") == true)
        XCTAssertTrue(result.summary.contains("hidden_primary="))
        XCTAssertTrue(result.summary.contains("links=1"))
    }
}
