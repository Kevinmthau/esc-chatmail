import XCTest
@testable import esc_chatmail

/// Compares the DOM-based quote remover against the legacy regex-based
/// `HTMLQuoteRemover` on representative inputs.
///
/// Strict HTML equality is not expected — SwiftSoup rewrites attribute order,
/// closing tags, and whitespace. Equality is checked at the plain-text level:
/// after running each implementation, we extract plain text and compare for
/// structural equivalence (response present, quote absent).
///
/// If a parity test fails, treat it as a behavioral divergence to investigate
/// before flipping the feature flag default.
final class EmailDOMQuoteRemoverParityTests: XCTestCase {

    private struct Case {
        let name: String
        let html: String
        let visibleTextSubstrings: [String]
        let hiddenTextSubstrings: [String]
        let mode: HTMLQuoteRemover.RemovalMode
    }

    private let parityCases: [Case] = [
        Case(
            name: "gmail_quote drops quoted content",
            html: """
            <p>My response here.</p>
            <div class="gmail_quote"><p>Original quoted content</p></div>
            """,
            visibleTextSubstrings: ["My response here."],
            hiddenTextSubstrings: ["Original quoted content"],
            mode: .quotedAndSignatures
        ),
        Case(
            name: "apple mail blockquote[type=cite]",
            html: """
            <p>Quick reply.</p>
            <blockquote type="cite"><p>Earlier message body</p></blockquote>
            """,
            visibleTextSubstrings: ["Quick reply."],
            hiddenTextSubstrings: ["Earlier message body"],
            mode: .quotedAndSignatures
        ),
        Case(
            name: "outlook reference container truncates",
            html: """
            <p>Reply text.</p>
            <div id="mail-editor-reference-message-container">
              <p>Older thread</p>
            </div>
            <p>This trailing content should also be removed because truncation applies forward.</p>
            """,
            visibleTextSubstrings: ["Reply text."],
            hiddenTextSubstrings: ["Older thread", "trailing content should also be removed"],
            mode: .quotedAndSignatures
        ),
        Case(
            name: "on date wrote text marker",
            html: """
            <div>My reply text.</div>
            <div>On Mon, Jan 15, 2024 at 10:30 AM Some Sender wrote:</div>
            <blockquote>Previous message</blockquote>
            """,
            visibleTextSubstrings: ["My reply text."],
            hiddenTextSubstrings: ["Previous message", "Some Sender wrote"],
            mode: .quotedAndSignatures
        ),
        Case(
            name: "gmail signature removed in signature mode",
            html: """
            <div>Hello team.</div>
            <div class="gmail_signature">--<br>Sent from my iPhone</div>
            """,
            visibleTextSubstrings: ["Hello team."],
            hiddenTextSubstrings: ["Sent from my iPhone"],
            mode: .quotedAndSignatures
        )
    ]

    func test_parity_visibleAndHiddenTextMatchesAcrossImplementations() {
        for parityCase in parityCases {
            // Reference: legacy regex pipeline
            let legacyHTML = HTMLQuoteRemover.removeQuotes(from: parityCase.html, mode: parityCase.mode)
            let legacyText = plainText(legacyHTML)

            // New: DOM pipeline
            let domHTML = EmailDOMQuoteRemover.removeQuotes(from: parityCase.html, mode: parityCase.mode)
            let domText = plainText(domHTML)

            for substring in parityCase.visibleTextSubstrings {
                XCTAssertTrue(
                    legacyText.contains(substring),
                    "[\(parityCase.name)] legacy lost expected visible text: '\(substring)'\nfull: \(legacyText)"
                )
                XCTAssertTrue(
                    domText.contains(substring),
                    "[\(parityCase.name)] dom lost expected visible text: '\(substring)'\nfull: \(domText)"
                )
            }
            for substring in parityCase.hiddenTextSubstrings {
                XCTAssertFalse(
                    legacyText.contains(substring),
                    "[\(parityCase.name)] legacy leaked hidden text: '\(substring)'\nfull: \(legacyText)"
                )
                XCTAssertFalse(
                    domText.contains(substring),
                    "[\(parityCase.name)] dom leaked hidden text: '\(substring)'\nfull: \(domText)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func plainText(_ html: String?) -> String {
        guard let html else { return "" }
        // Extract through the legacy regex extractor so this helper doesn't
        // depend on the DOM text extractor we are also exercising.
        return TextProcessing.extractPlainText(from: html)
    }
}
