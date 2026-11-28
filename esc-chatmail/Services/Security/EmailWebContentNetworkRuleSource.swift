import Foundation

/// The WebKit content rule list that keeps email HTML from reaching private, loopback, link-local
/// and reserved hosts through a web view's own subresource loads: an `<img>`, a CSS `url()`, a
/// font, a video poster (architecture review 2026-11, `security-privacy#2`,
/// `web-content-rendering#5`). The app's native fetches of a sender's URLs are checked by
/// `PrivateNetworkAddressDetector` and `SSRFGuardingURLSession`; WebKit's own loads never went
/// through either, so a crafted email made the device send blind requests to loopback and LAN
/// hosts, with no click, from every web view that rendered it.
///
/// The rules are generated from the detector's own ranges and names, so the two cannot drift:
/// - Every IPv4 range in `PrivateNetworkAddressDetector.privateIPv4Ranges`, written as the
///   canonical dotted-decimal host. WebKit matches a load's URL after its URL parser has
///   canonicalized the host, so one spelling covers them all: measured on the iOS 27.0 simulator,
///   `0x7f.1`, `2130706433`, `127.1`, `0177.0.0.1`, `127.0.0.1.`, `%31%32%37.0.0.1`, full-width
///   digits and a `user:pw@` userinfo were each refused by the `127` rule.
/// - Every IPv6 literal. The detector refuses only the private ones, but an email's resources are
///   never on an address literal, and a bracketed host covers the IPv4-mapped spelling of a
///   private address (`[::ffff:127.0.0.1]`, measured) without a rule for each form.
/// - `PrivateNetworkAddressDetector.reservedHostnames` and every name under
///   `PrivateNetworkAddressDetector.reservedTLDs` (`localhost`, `.local`, `.internal`, …).
/// - Every single-label name (`http://printer/`), as the detector refuses them.
///
/// Three things about WebKit's matcher shape the patterns, measured on the same simulator:
/// - Its regular expressions take no alternation (`|`), no counted repetition (`{n}`) and no
///   `\d`: a list holding any of them fails to compile. So a range whose mask ends inside an
///   octet is one rule for each value of that octet (100.64.0.0/10 is 64 rules), not one rule
///   with an alternation.
/// - `url-filter` is matched against the whole URL, userinfo included, so every pattern takes an
///   optional userinfo, and ends at the path's slash after an optional port. Without that end, a
///   public URL with a userinfo (`http://user:pw@example.com/`) would match the single-label rule
///   at `user:`.
/// - No rule names the `document` type: the documents the app loads are its own
///   `loadHTMLString` calls, whose base URL is the sender's domain, and a sender on a `.local`
///   domain must still be readable. Measured: a document loaded with a single-label base URL
///   loads under this list. `popup` is left out too: a link the user taps is decided by the
///   reader's navigation policy, which refuses private hosts itself and logs it
///   (`FullInteractiveEmailWebView.navigationDecision`).
///
/// It changes which images load only for those hosts. Which public images load, tracking pixels
/// included, is the image-consent question, which is Kevin's to decide and is not here.
///
/// A name that resolves to a private address is not covered, as for the detector: WebKit resolves
/// it after the rules have matched.
enum EmailWebContentNetworkRuleSource {
    /// Every subresource type WebKit's rule lists name, `document` and `popup` left out (see the
    /// type's note).
    static let blockedResourceTypes = [
        "image",
        "style-sheet",
        "script",
        "font",
        "raw",
        "svg-document",
        "media",
        "ping",
        "fetch",
        "websocket",
        "other"
    ]

    /// A scheme WebKit loads from the network, then an optional userinfo. The userinfo cannot hold
    /// a `/`, `?`, `#` or a second `@`: WebKit's canonical URL percent-encodes them.
    static let authorityStart = #"^https?://([^/?#@]*@)?"#

    /// The end of a host: an optional trailing dot (kept on a name by WebKit's parser), an
    /// optional port, then the path's slash, which a canonical http(s) URL always has.
    static let authorityEnd = #"\.?(:[0-9]*)?/"#

    /// The `url-filter` of every rule, in a fixed order.
    static var urlFilters: [String] {
        ipv4Filters + [ipv6LiteralFilter] + reservedHostnameFilters + reservedTLDFilters
            + [singleLabelFilter]
    }

    static var ipv4Filters: [String] {
        PrivateNetworkAddressDetector.privateIPv4Ranges.flatMap { range in
            ipv4Filters(network: range.network, mask: range.mask)
        }
    }

    /// Any host in brackets, which in a canonical URL is an IPv6 literal.
    static let ipv6LiteralFilter = authorityStart + #"\["#

    static var reservedHostnameFilters: [String] {
        PrivateNetworkAddressDetector.reservedHostnames.sorted().map { name in
            authorityStart + escaped(name) + authorityEnd
        }
    }

    static var reservedTLDFilters: [String] {
        PrivateNetworkAddressDetector.reservedTLDs.sorted().map { tld in
            authorityStart + #"[^/?#@:\[]*\."# + escaped(tld) + authorityEnd
        }
    }

    /// A host with no dot (and no bracket: an IPv6 literal has its own rule).
    static let singleLabelFilter = authorityStart + #"[^./?#:@\[]+"# + authorityEnd

    /// The rules as WebKit's JSON.
    static var encodedRuleList: String {
        let rules: [[String: Any]] = urlFilters.map { filter in
            [
                "trigger": [
                    "url-filter": filter,
                    "resource-type": blockedResourceTypes
                ] as [String: Any],
                "action": ["type": "block"]
            ]
        }
        // The input is fixed and always serializable. An empty list is never what is compiled: the
        // provider refuses to call a list of no rules ready (`EmailWebContentNetworkRules`).
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// The canonical dotted-decimal hosts of one range. Whole octets of the prefix are written
    /// out; an octet the mask ends inside is one filter for each value it can take; the rest are
    /// any decimal octet.
    static func ipv4Filters(network: UInt32, mask: UInt32) -> [String] {
        let prefixLength = mask.nonzeroBitCount
        let octets = (0..<4).map { index in Int((network >> UInt32(24 - 8 * index)) & 0xFF) }
        let fixedOctetCount = prefixLength / 8
        let partialBits = prefixLength % 8

        var heads: [[String]] = [octets.prefix(fixedOctetCount).map(String.init)]
        var remainingOctets = 4 - fixedOctetCount
        if partialBits > 0 {
            let first = octets[fixedOctetCount]
            let span = 1 << (8 - partialBits)
            heads = (first..<(first + span)).map { value in heads[0] + [String(value)] }
            remainingOctets -= 1
        }

        return heads.map { head in
            let parts = head + Array(repeating: "[0-9]+", count: remainingOctets)
            return authorityStart + parts.joined(separator: #"\."#) + authorityEnd
        }
    }

    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: #"\."#)
    }
}
