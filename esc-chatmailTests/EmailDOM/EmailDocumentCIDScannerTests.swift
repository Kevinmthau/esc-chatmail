import XCTest
@testable import esc_chatmail

/// Tests for the shared regex-free `cid:` scanner that replaced five hand-rolled
/// copies across the message, bubble, and web-view layers. These lock in the
/// behaviors each former call site depended on — in particular the differing
/// terminator sets and the value-start index used by the signature heuristic.
final class EmailDocumentCIDScannerTests: XCTestCase {

    // MARK: - referencedContentIDs (Set convenience)

    func testReferencedContentIDs_singleSrc_normalizedAndLowercased() {
        let html = #"<img src="cid:ABC123">"#
        XCTAssertEqual(EmailDocument.referencedContentIDs(in: html), ["abc123"])
    }

    func testReferencedContentIDs_multiple_dedupesAndIsCaseInsensitive() {
        let html = #"<img src="cid:one"><img src="CID:two"><img src="cid:one">"#
        XCTAssertEqual(EmailDocument.referencedContentIDs(in: html), ["one", "two"])
    }

    func testReferencedContentIDs_noReferences_returnsEmpty() {
        XCTAssertEqual(EmailDocument.referencedContentIDs(in: "<p>hello</p>"), [])
    }

    func testReferencedContentIDs_emptyValue_isSkipped() {
        // `cid:` immediately followed by a terminator yields no identifier.
        XCTAssertEqual(EmailDocument.referencedContentIDs(in: #"<img src="cid:">"#), [])
    }

    func testReferencedContentIDs_trailingReferenceAtEndOfString_isCaptured() {
        XCTAssertEqual(EmailDocument.referencedContentIDs(in: "cid:tail"), ["tail"])
    }

    // MARK: - Terminator sets

    func testTerminators_attributeVsCss_differOnClosingParen() {
        // Historical behavior: the attribute scanner (src="cid:…") does NOT treat
        // ")" as a terminator, so a CSS `url(cid:logo)` reference keeps the paren;
        // the CSS scanner stops at it. Both variants are preserved deliberately.
        let css = "background:url(cid:logo)"
        XCTAssertEqual(
            EmailDocument.referencedContentIDs(in: css, terminators: EmailDocument.CIDScanTerminators.attribute),
            ["logo)"]
        )
        XCTAssertEqual(
            EmailDocument.referencedContentIDs(in: css, terminators: EmailDocument.CIDScanTerminators.css),
            ["logo"]
        )
    }

    func testTerminators_cssAndWhitespace_stopsAtRawWhitespace() {
        // The web-view fingerprint scanner additionally stops at \n, \r, \t.
        let html = "src=cid:abc\tnext"
        XCTAssertEqual(
            EmailDocument.referencedContentIDs(in: html, terminators: EmailDocument.CIDScanTerminators.cssAndWhitespace),
            ["abc"]
        )
    }

    // MARK: - scanReferencedContentIDs (closure form)

    func testScan_reportsValueStartIndexForEachReference() {
        // The signature heuristic keys off where in the document a CID begins, so
        // the closure must report the index immediately after "cid:".
        let html = "xx cid:abc"
        var offsets: [Int] = []
        EmailDocument.scanReferencedContentIDs(in: html) { _, valueStart in
            offsets.append(html.distance(from: html.startIndex, to: valueStart))
        }
        XCTAssertEqual(offsets, [7])
    }

    func testScan_invokesHandlerOncePerNormalizedReference_inOrder() {
        let html = #"<img src="cid:first"><img src="cid:second">"#
        var seen: [String] = []
        EmailDocument.scanReferencedContentIDs(in: html) { contentID, _ in
            seen.append(contentID)
        }
        XCTAssertEqual(seen, ["first", "second"])
    }

    func testScan_skipsReferencesThatFailNormalization() {
        // Empty identifiers never reach the handler.
        var count = 0
        EmailDocument.scanReferencedContentIDs(in: #"a cid:" b cid:"#) { _, _ in count += 1 }
        XCTAssertEqual(count, 0)
    }
}
