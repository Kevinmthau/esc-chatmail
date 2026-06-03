import WebKit
import XCTest
@testable import esc_chatmail

final class FullEmailWebViewPoolBookkeepingTests: XCTestCase {
    func testTouchKeepsMostRecentlyUsedAndDoesNotEvictUnderCapacity() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.touch("b"), [])
        XCTAssertEqual(pool.touch("c"), [])
        XCTAssertEqual(pool.order, ["a", "b", "c"])
    }

    func testTouchEvictsLeastRecentlyUsedOverCapacity() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 2)
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.touch("b"), [])
        // "c" overflows capacity → "a" (LRU) evicted.
        XCTAssertEqual(pool.touch("c"), ["a"])
        XCTAssertEqual(pool.order, ["b", "c"])
    }

    func testReTouchRefreshesRecencySoADifferentEntryIsEvicted() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 2)
        _ = pool.touch("a")
        _ = pool.touch("b")
        // Re-touch "a" → it becomes most-recently-used; "b" is now LRU.
        _ = pool.touch("a")
        XCTAssertEqual(pool.order, ["b", "a"])
        XCTAssertEqual(pool.touch("c"), ["b"])
        XCTAssertEqual(pool.order, ["a", "c"])
    }

    func testTouchIsIdempotentForSameId() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        _ = pool.touch("a")
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.order, ["a"])
    }

    func testRemoveDropsEntry() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        _ = pool.touch("a")
        _ = pool.touch("b")
        pool.remove("a")
        XCTAssertEqual(pool.order, ["b"])
    }

    func testRemoveAllClears() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 3)
        _ = pool.touch("a")
        _ = pool.touch("b")
        pool.removeAll()
        XCTAssertEqual(pool.order, [])
    }

    func testCapacityIsAtLeastOne() {
        var pool = FullEmailWebViewPoolBookkeeping(capacity: 0)
        XCTAssertEqual(pool.touch("a"), [])
        XCTAssertEqual(pool.touch("b"), ["a"])
        XCTAssertEqual(pool.order, ["b"])
    }
}

final class FullEmailWebViewPreRenderKeyTests: XCTestCase {
    private func makeKey(
        messageId: String = "m1",
        html: String = "<html>body</html>",
        cid: String = "cid:none",
        width: CGFloat = 390
    ) -> FullEmailWebViewPreRenderKey {
        FullEmailWebViewPreRenderKey.make(
            messageId: messageId,
            wrappedHTML: html,
            cidAvailabilityFingerprint: cid,
            width: width
        )
    }

    func testIdenticalInputsProduceEqualKeys() {
        XCTAssertEqual(makeKey(), makeKey())
    }

    func testDifferentHTMLProducesDifferentKey() {
        XCTAssertNotEqual(makeKey(html: "<html>a</html>"), makeKey(html: "<html>b</html>"))
    }

    func testDifferentMessageIdProducesDifferentKey() {
        XCTAssertNotEqual(makeKey(messageId: "m1"), makeKey(messageId: "m2"))
    }

    func testDifferentCIDAvailabilityProducesDifferentKey() {
        XCTAssertNotEqual(makeKey(cid: "cid:none"), makeKey(cid: "cid:available"))
    }

    func testWidthIsBucketedToNearestPoint() {
        // Sub-point jitter collapses to the same bucket.
        XCTAssertEqual(makeKey(width: 390.2), makeKey(width: 390.4))
        // A full-point difference is a different bucket (would re-layout if adopted).
        XCTAssertNotEqual(makeKey(width: 390), makeKey(width: 391))
    }

    func testHTMLFingerprintIncludesLengthGuardingAgainstCollisions() {
        // Same prefix, different length must not collide.
        XCTAssertNotEqual(makeKey(html: "abc"), makeKey(html: "abcd"))
    }
}

final class FullInteractiveEmailWebViewNavigationDecisionTests: XCTestCase {
    private func decide(_ type: WKNavigationType, _ urlString: String?) -> FullInteractiveEmailWebView.NavigationDecision {
        FullInteractiveEmailWebView.navigationDecision(
            navigationType: type,
            url: urlString.flatMap(URL.init(string:))
        )
    }

    func testInitialAndReloadNavigationsAreAllowed() {
        XCTAssertEqual(decide(.other, "about:blank"), .allow)
        XCTAssertEqual(decide(.other, "https://example.com"), .allow)
        XCTAssertEqual(decide(.reload, "https://example.com"), .allow)
    }

    func testLinkActivationToPublicURLOpensExternally() {
        let url = URL(string: "https://example.com/path")!
        XCTAssertEqual(decide(.linkActivated, "https://example.com/path"), .openExternally(url))
    }

    func testLinkActivationToBlankURLIsCancelled() {
        XCTAssertEqual(decide(.linkActivated, "about:blank"), .cancel)
    }

    func testLinkActivationWithUnparseableURLFallsThroughToAllow() {
        // An empty string is not a parseable URL, so `request.url` is nil — matching the pre-refactor
        // coordinator, which allowed navigations whose URL was nil.
        XCTAssertEqual(decide(.linkActivated, ""), .allow)
    }

    func testUnsupportedSchemesAreCancelled() {
        XCTAssertEqual(decide(.linkActivated, "javascript:alert(1)"), .cancel)
        XCTAssertEqual(decide(.linkActivated, "vbscript:foo"), .cancel)
        XCTAssertEqual(decide(.linkActivated, "file:///etc/passwd"), .cancel)
    }

    func testDataDetectorLinksAreAllowed() {
        XCTAssertEqual(decide(.linkActivated, "x-apple-data-detectors://1"), .allow)
    }

    func testPrivateOrReservedLinksAreBlocked() {
        // Loopback / private hosts must never open from email content. They resolve to a distinct
        // `blockedPrivateNetwork` decision (carrying the URL) so the live coordinator can log the
        // block; the warm delegate treats it as a plain cancel.
        let loopback = URL(string: "http://127.0.0.1/admin")!
        let privateHost = URL(string: "http://192.168.0.1/")!
        XCTAssertEqual(decide(.linkActivated, "http://127.0.0.1/admin"), .blockedPrivateNetwork(loopback))
        XCTAssertEqual(decide(.linkActivated, "http://192.168.0.1/"), .blockedPrivateNetwork(privateHost))
    }

    func testNonLinkNavigationsFallThroughToAllow() {
        // e.g. form submissions to a normal URL are allowed (matches pre-refactor behavior).
        XCTAssertEqual(decide(.formSubmitted, "https://example.com/submit"), .allow)
    }
}
