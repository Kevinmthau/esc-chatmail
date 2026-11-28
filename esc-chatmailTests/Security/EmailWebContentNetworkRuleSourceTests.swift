import Foundation
import XCTest
@testable import esc_chatmail

/// The rule list's patterns, evaluated here with `NSRegularExpression`, which reads the subset
/// WebKit's matcher takes (`^`, groups, `?`, `+`, `*`, classes) the same way. What WebKit itself
/// does with them is `EmailWebContentPrivateNetworkLoadTests`'.
final class EmailWebContentNetworkRuleSourceTests: XCTestCase {
    private lazy var filters: [NSRegularExpression] = EmailWebContentNetworkRuleSource.urlFilters.map {
        // url-filter-is-case-sensitive is false by default.
        try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    private func isBlocked(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..., in: url)
        return filters.contains { $0.firstMatch(in: url, range: range) != nil }
    }

    /// The rules and the detector agree on every canonical dotted-decimal host sampled across the
    /// whole IPv4 space: each first octet, a spread of second octets (every value where a range's
    /// mask ends in the second octet), and the ends of each range.
    ///
    /// Revert-check: dropping a range's filters from `ipv4Filters`, or writing a partial octet's
    /// span one short (`first + span - 1`), fails this.
    func testIPv4Filters_agreeWithTheDetector_acrossTheAddressSpace() throws {
        var addresses: [UInt32] = []
        for first in UInt32(0)...255 {
            for second in stride(from: UInt32(0), through: 255, by: first == 100 || first == 172 || first == 198 ? 1 : 37) {
                addresses.append(first << 24 | second << 16 | 0x0101)
            }
        }
        for range in PrivateNetworkAddressDetector.privateIPv4Ranges {
            let last = range.network | ~range.mask
            addresses += [range.network, last, range.network &- 1, last &+ 1]
        }

        var disagreements: [String] = []
        for address in addresses {
            let host = [24, 16, 8, 0].map { String((address >> UInt32($0)) & 0xFF) }.joined(separator: ".")
            let url = "http://\(host)/pixel.gif"
            let detector = PrivateNetworkAddressDetector.isPrivateOrReserved(try XCTUnwrap(URL(string: url)))
            if detector != isBlocked(url) {
                disagreements.append("\(host): detector=\(detector) rules=\(isBlocked(url))")
            }
        }
        XCTAssertEqual(disagreements, [])
    }

    /// A range whose mask ends inside an octet is one filter per value, because WebKit's matcher
    /// takes no alternation.
    func testIPv4Filters_partialOctet_isOneFilterPerValue() {
        XCTAssertEqual(
            EmailWebContentNetworkRuleSource.ipv4Filters(network: 0xAC100000, mask: 0xFFF00000).count,
            16
        )
        XCTAssertEqual(
            EmailWebContentNetworkRuleSource.ipv4Filters(network: 0xFFFFFFFF, mask: 0xFFFFFFFF),
            [#"^https?://([^/?#@]*@)?255\.255\.255\.255\.?(:[0-9]*)?/"#]
        )
    }

    /// Names: the detector's reserved names and TLDs, single labels and any IPv6 literal are
    /// refused, with or without a port, a userinfo or a trailing dot; public names are not, a
    /// userinfo before them and a numeric first label included.
    ///
    /// Revert-check: dropping `authorityEnd`'s slash from the single-label filter, so a label may
    /// end at any `:`, makes `http://user:pw@example.com/` blocked and fails this; dropping the
    /// optional userinfo group lets `http://user:pw@nas.local/` through.
    func testNameFilters_refuseReservedNamesAndKeepPublicOnes() {
        let blocked = [
            "http://localhost/x",
            "http://localhost:8080/x",
            "http://LOCALHOST./x",
            "http://localhost.localdomain/x",
            "http://foo.localhost/x",
            "http://nas.local/x",
            "http://user:pw@nas.local/x",
            "https://printer/x",
            "http://printer.:631/x",
            "http://metadata.internal/x",
            "http://a.b.corp/x",
            "http://site.onion/x",
            "http://[::1]/x",
            "http://[::ffff:127.0.0.1]:8080/x",
            "http://[2001:db8::1]/x",
            "http://user@10.1.2.3/x",
            "http://169.254.169.254/latest/meta-data/"
        ]
        let allowed = [
            "https://example.com/x",
            "https://cdn.mailchimp.com/img.png",
            "http://user:pw@example.com/x",
            "http://user:123@example.com/x",
            "http://10.example.com/x",
            "http://example.com:8080/x",
            "https://8.8.8.8/x",
            "https://100.63.255.255/x",
            "https://172.32.0.1/x",
            "data:image/gif;base64,R0lGOD",
            "cid:image001.png@01D9",
            "about:blank"
        ]
        XCTAssertEqual(blocked.filter { !isBlocked($0) }, [])
        XCTAssertEqual(allowed.filter(isBlocked), [])
    }

    /// The list never names the document type, so the email documents the app loads itself (with
    /// the sender's domain as base URL) are never refused, and leaves `popup` to the reader's link
    /// policy.
    func testEncodedRuleList_blocksSubresourcesOnly() throws {
        let data = try XCTUnwrap(EmailWebContentNetworkRuleSource.encodedRuleList.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rules.count, EmailWebContentNetworkRuleSource.urlFilters.count)
        XCTAssertGreaterThan(rules.count, 100)
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let types = try XCTUnwrap(trigger["resource-type"] as? [String])
            XCTAssertFalse(types.contains("document"))
            XCTAssertFalse(types.contains("popup"))
            XCTAssertTrue(types.contains("image"))
            XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
        }
    }
}
