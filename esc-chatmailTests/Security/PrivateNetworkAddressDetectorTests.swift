import XCTest
@testable import esc_chatmail

final class PrivateNetworkAddressDetectorTests: XCTestCase {

    // MARK: - Public addresses should pass

    func testPublicIPv4_isAllowed() {
        assertAllowed("https://8.8.8.8/")
        assertAllowed("https://1.1.1.1/")
        assertAllowed("https://142.250.80.46/")
    }

    func testPublicIPv6_isAllowed() {
        assertAllowed("https://[2001:4860:4860::8888]/")
        assertAllowed("https://[2606:4700:4700::1111]/")
    }

    func testPublicFQDNs_areAllowed() {
        assertAllowed("https://example.com/")
        assertAllowed("https://docs.google.com/document/d/abc/edit")
        assertAllowed("https://drive.google.com/file/d/abc/view")
        assertAllowed("https://lh7-rt.googleusercontent.com/docsz/image")
        assertAllowed("https://cdn.beehiiv.com/foo.png")
    }

    // MARK: - IPv4 private ranges

    func testIPv4_loopback_isBlocked() {
        assertBlocked("http://127.0.0.1/")
        assertBlocked("http://127.255.255.254/")
        assertBlocked("https://127.1.2.3:8080/admin")
    }

    func testIPv4_privateRanges_areBlocked() {
        assertBlocked("http://10.0.0.1/")
        assertBlocked("http://10.255.255.255/")
        assertBlocked("http://172.16.0.1/")
        assertBlocked("http://172.31.255.254/")
        assertBlocked("http://192.168.0.1/")
        assertBlocked("http://192.168.1.1/router-admin")
    }

    func testIPv4_linkLocalAndMetadata_areBlocked() {
        // 169.254.169.254 is the AWS/GCP/Azure instance metadata endpoint.
        assertBlocked("http://169.254.169.254/latest/meta-data/")
        assertBlocked("http://169.254.0.1/")
        assertBlocked("http://169.254.255.255/")
    }

    func testIPv4_cgnat_isBlocked() {
        assertBlocked("http://100.64.0.1/")
        assertBlocked("http://100.127.255.254/")
    }

    func testIPv4_testAndDocRanges_areBlocked() {
        assertBlocked("http://192.0.2.1/")       // TEST-NET-1
        assertBlocked("http://198.51.100.1/")    // TEST-NET-2
        assertBlocked("http://203.0.113.1/")     // TEST-NET-3
        assertBlocked("http://198.18.0.1/")      // benchmarking
    }

    func testIPv4_multicastAndBroadcast_areBlocked() {
        assertBlocked("http://224.0.0.1/")       // multicast
        assertBlocked("http://239.255.255.255/") // multicast
        assertBlocked("http://240.0.0.1/")       // reserved
        assertBlocked("http://255.255.255.255/") // limited broadcast
    }

    func testIPv4_zeroNet_isBlocked() {
        assertBlocked("http://0.0.0.0/")
        assertBlocked("http://0.1.2.3/")
    }

    // MARK: - IPv4 legacy-form bypasses

    func testIPv4_integerForm_resolvesToLoopback_isBlocked() {
        // 2130706433 decimal == 0x7F000001 == 127.0.0.1
        assertBlocked("http://2130706433/")
    }

    func testIPv4_hexForm_resolvesToLoopback_isBlocked() {
        assertBlocked("http://0x7f.0.0.1/")
        assertBlocked("http://0x7f000001/")
    }

    func testIPv4_octalForm_resolvesToLoopback_isBlocked() {
        // 0177 octal == 127 decimal
        assertBlocked("http://0177.0.0.1/")
    }

    func testIPv4_shortForm_isBlocked() {
        // inet_aton: "127" -> 127.0.0.0 (in 127/8)
        assertBlocked("http://127/")
    }

    // MARK: - IPv4 leading-zero parts (two readings)

    /// A dotted quad with a leading-zero part has two readings: `inet_aton` and WebKit read the
    /// part as octal, the system resolver reads it as decimal. Measured on the iOS 27.0 simulator:
    /// `getaddrinfo("0127.0.0.1")` is 127.0.0.1, and a `URLSession` GET of
    /// `http://0127.0.0.1:<port>/` returned 200 from a loopback listener, while the detector took
    /// only the octal reading (87.0.0.1) and classed the host public.
    ///
    /// Revert-check: returning only the `inet_aton` reading from
    /// `PrivateNetworkAddressDetector.ipv4Readings(of:)`, without the dotted-decimal one, makes
    /// this fail.
    func testIPv4_leadingZeroPart_privateWhenReadAsDecimal_isBlocked() {
        assertBlocked("http://010.0.0.1/cgi-bin/reboot")             // octal: 8.0.0.1
        assertBlocked("http://00010.0.0.1/")                         // octal: 8.0.0.1
        assertBlocked("http://0127.0.0.1/")                          // octal: 87.0.0.1
        assertBlocked("http://0172.16.0.1/")                         // octal: 122.16.0.1
        assertBlocked("http://172.016.0.1/")                         // octal: 172.14.0.1
        assertBlocked("http://169.0254.169.254/latest/meta-data/")   // octal: 169.172.169.254
        assertBlocked("http://0100.64.0.1/")                         // octal: 64.64.0.1
        assertBlocked("http://010.0.0.1./")                          // and with a trailing dot
    }

    /// The octal reading stays, because it is how WebKit reads the host. Measured on the iOS 27.0
    /// simulator, its URL parser reads these as 10.0.0.1, 127.0.0.1 and 192.168.0.1, although
    /// `getaddrinfo` reads `0177.0.0.1` as 177.0.0.1.
    ///
    /// Revert-check: returning only the dotted-decimal reading from
    /// `PrivateNetworkAddressDetector.ipv4Readings(of:)`, without the `inet_aton` one, makes this
    /// fail.
    func testIPv4_leadingZeroPart_privateWhenReadAsOctal_isBlocked() {
        assertBlocked("http://012.0.0.1/")       // decimal: 12.0.0.1
        assertBlocked("http://0177.0.0.1/")      // decimal: 177.0.0.1
        assertBlocked("http://0300.0250.0.1/")   // octal: 192.168.0.1; not a decimal quad
    }

    /// `inet_aton` rejects these (8 and 9 are not octal digits), so the decimal reading is the
    /// only one.
    ///
    /// HONEST SCOPE: these were blocked before the two-readings change, by an `inet_pton`
    /// fallback. They pin that replacing it with the dotted-decimal reading kept them blocked, and
    /// the same Revert-check as `testIPv4_leadingZeroPart_privateWhenReadAsDecimal_isBlocked`
    /// makes them fail.
    func testIPv4_leadingZeroPart_notOctal_isBlocked() {
        assertBlocked("http://0192.168.0.1/")
        assertBlocked("http://192.0168.0.1/")
        assertBlocked("http://192.168.0.09/")
    }

    /// A leading zero alone must not refuse a host: each of these is public under every reading.
    ///
    /// Revert-check: refusing every dotted quad that has a leading-zero part in
    /// `PrivateNetworkAddressDetector.ipv4Readings(of:)`, instead of classifying its readings,
    /// makes this fail.
    func testIPv4_leadingZeroPart_publicUnderEveryReading_isAllowed() {
        assertAllowed("https://08.8.8.8/")     // not octal; decimal: 8.8.8.8
        assertAllowed("https://01.1.1.1/")     // 1.1.1.1 either way
        assertAllowed("https://8.8.8.010/")    // octal: 8.8.8.8; decimal: 8.8.8.10
    }

    // MARK: - IPv6 private ranges

    func testIPv6_loopback_isBlocked() {
        assertBlocked("http://[::1]/")
    }

    func testIPv6_unspecified_isBlocked() {
        assertBlocked("http://[::]/")
    }

    func testIPv6_linkLocal_isBlocked() {
        assertBlocked("http://[fe80::1]/")
        assertBlocked("http://[fe80::abcd:1234]/")
    }

    func testIPv6_scopedLiterals_areBlocked() {
        assertBlocked("http://[::1%25lo0]/")
        assertBlocked("http://[fe80::1%25en0]/")
    }

    func testIPv6_uniqueLocal_isBlocked() {
        assertBlocked("http://[fc00::1]/")
        assertBlocked("http://[fd12:3456:789a::1]/")
    }

    func testIPv6_multicast_isBlocked() {
        assertBlocked("http://[ff02::1]/")
    }

    func testIPv6_ipv4Mapped_resolvesToLoopback_isBlocked() {
        // ::ffff:127.0.0.1 — an IPv4-mapped form that points at loopback.
        assertBlocked("http://[::ffff:127.0.0.1]/")
    }

    func testIPv6_ipv4Mapped_resolvesToMetadata_isBlocked() {
        assertBlocked("http://[::ffff:169.254.169.254]/")
    }

    // MARK: - Reserved hostnames and TLDs

    func testReservedHostnames_areBlocked() {
        assertBlocked("http://localhost/")
        assertBlocked("http://localhost:8080/")
        assertBlocked("http://LOCALHOST/")  // case-insensitive
        assertBlocked("http://ip6-loopback/")
    }

    func testReservedTLDs_areBlocked() {
        assertBlocked("http://printer.local/")
        assertBlocked("http://router.lan/")
        assertBlocked("http://gateway.internal/")
        assertBlocked("http://server.corp/")
        assertBlocked("http://something.home/")
        assertBlocked("http://example.test/")
        assertBlocked("http://foo.invalid/")
        assertBlocked("http://secret.onion/")
    }

    func testSingleLabelHostname_isBlocked() {
        assertBlocked("http://intranet-server/")
        assertBlocked("http://printer/")
    }

    // MARK: - Trailing-dot (fully qualified) hosts

    /// One trailing dot only marks a name as fully qualified, and whatever opens the URL drops
    /// it. Measured on the iOS 27.0 simulator: WebKit's URL parser reads `http://192.168.0.1./` as
    /// the host `192.168.0.1`, and `getaddrinfo("192.168.0.1.")` resolves to 192.168.0.1.
    ///
    /// Revert-check: classifying `url.host` as given in
    /// `PrivateNetworkAddressDetector.classifiableHost(of:)`, without dropping the trailing dot,
    /// makes this fail: `inet_aton` rejects the dotted form and the host falls through to public.
    func testIPv4_trailingDot_isBlocked() {
        assertBlocked("http://192.168.0.1./admin?action=reset")
        assertBlocked("http://127.0.0.1./")
        assertBlocked("http://10.0.0.1./")
        assertBlocked("http://169.254.169.254./latest/meta-data/")
    }

    /// WebKit reads the first four as 127.0.0.1, `127.` as 0.0.0.127 and `0.` as 0.0.0.0.
    ///
    /// Revert-check: the same revert makes this fail.
    func testIPv4_legacyFormsWithTrailingDot_areBlocked() {
        assertBlocked("http://127.1./")
        assertBlocked("http://2130706433./")
        assertBlocked("http://0x7f.1./")
        assertBlocked("http://0177.0.0.1./")
        assertBlocked("http://127./")
        assertBlocked("http://0./")
    }

    /// Foundation hands both of these to the detector as the host `192.168.0.1.`.
    ///
    /// Revert-check: the same revert makes this fail.
    func testIPv4_encodedOrIdeographicTrailingDot_isBlocked() {
        assertBlocked("http://192.168.0.1%2E/")
        assertBlocked("http://192.168.0.1\u{3002}/")
    }

    /// A URL bridged from `NSURL`, which is what a redirect and a WebView click deliver, carries
    /// the same dotted host.
    ///
    /// Revert-check: the same revert makes this fail.
    func testIPv4_trailingDot_bridgedFromNSURL_isBlocked() throws {
        let url = try XCTUnwrap(NSURL(string: "http://192.168.0.1./admin")) as URL

        XCTAssertEqual(url.host, "192.168.0.1.")
        XCTAssertTrue(PrivateNetworkAddressDetector.isPrivateOrReserved(url))
    }

    /// With the dot, `printer.` did not look like a single label.
    ///
    /// Revert-check: the same revert makes this fail.
    func testSingleLabelHostname_trailingDot_isBlocked() {
        assertBlocked("http://intranet-server./")
        assertBlocked("http://printer./")
    }

    /// HONEST SCOPE: these were blocked before the trailing dot was dropped, by the reserved-TLD
    /// check, which skips empty labels. They pin that the change keeps them blocked.
    func testReservedNames_trailingDot_areBlocked() {
        assertBlocked("http://localhost./")
        assertBlocked("http://LOCALHOST./")
        assertBlocked("http://printer.local./")
    }

    /// A host with an empty label is not a usable name: WebKit kept `192.168.0.1..` as a name and
    /// `getaddrinfo` failed on it and on `.`.
    ///
    /// Revert-check: removing the `!host.hasSuffix(".")` and `!host.isEmpty` refusals after the
    /// dot is dropped in `PrivateNetworkAddressDetector.classifiableHost(of:)` makes this fail.
    func testHostWithEmptyLabel_isBlocked() {
        assertBlocked("http://192.168.0.1../")
        assertBlocked("http://example.com../")
        assertBlocked("http://./")
    }

    /// Dropping the dot must not turn a public name private.
    ///
    /// Revert-check: refusing every host that ends in a dot in
    /// `PrivateNetworkAddressDetector.classifiableHost(of:)`, instead of dropping the dot, makes
    /// this fail.
    func testPublicHosts_trailingDot_areAllowed() {
        assertAllowed("https://example.com./")
        assertAllowed("https://docs.google.com./document/d/abc/edit")
        assertAllowed("https://8.8.8.8./")
    }

    // MARK: - Percent-encoded non-ASCII hosts

    /// Foundation leaves a percent-encoded host alone, so these reach the detector as non-ASCII
    /// hosts (`127.0.0.1．`, `１２７.0.0.1`) that none of its checks can read, and they were classed
    /// public. WebKit decodes and maps them when it opens the URL: measured on the iOS 27.0
    /// simulator, its URL parser reads the first six as `127.0.0.1` and the last as
    /// `printer.local`.
    ///
    /// Revert-check: removing the non-ASCII refusal from
    /// `PrivateNetworkAddressDetector.classifiableHost(of:)` makes this fail.
    ///
    /// HONEST SCOPE: measured on iOS 27.0 only. On a runtime whose Foundation mapped a
    /// percent-encoded host to ASCII, the other checks would block these with or without the
    /// refusal.
    func testPercentEncodedNonASCIIHost_isBlocked() {
        assertBlocked("http://127.0.0.1%EF%BC%8E/admin")              // fullwidth full stop
        assertBlocked("http://127.0.0.1%E3%80%82/admin")              // ideographic full stop
        assertBlocked("http://127.0.0.1%EF%BD%A1/admin")              // halfwidth ideographic full stop
        assertBlocked("http://%EF%BC%91%EF%BC%92%EF%BC%97.0.0.1/")    // fullwidth digits
        assertBlocked("http://127.0.0.1%C2%AD/")                      // soft hyphen
        assertBlocked("http://127.0.0.1%E2%80%8B/")                   // zero-width space
        assertBlocked("http://printer.%EF%BD%8Cocal/")                // fullwidth "l"
    }

    /// A URL bridged from `NSURL`, which is what a redirect delivers, carries the same non-ASCII
    /// host.
    ///
    /// Revert-check: the same revert makes this fail. HONEST SCOPE: as above.
    func testPercentEncodedNonASCIIHost_bridgedFromNSURL_isBlocked() throws {
        let url = try XCTUnwrap(NSURL(string: "http://192.168.0.1%EF%BC%8E/admin")) as URL

        XCTAssertTrue(PrivateNetworkAddressDetector.isPrivateOrReserved(url))
    }

    /// The refusal must not reach an ordinary internationalized name. Foundation hands a name
    /// written in Unicode to the detector in its ASCII `xn--` form, like one written that way.
    ///
    /// HONEST SCOPE: this passes with or without the refusal. It pins what the refusal rests on:
    /// on a runtime whose Foundation handed the Unicode name over unmapped, every such link would
    /// be refused and this would fail.
    func testInternationalizedPublicName_isAllowed() {
        assertAllowed("https://b\u{00FC}cher.example.com/")
        assertAllowed("https://xn--bcher-kva.example.com/")
    }

    /// The cost of the refusal: a public name whose host is percent-encoded is refused too. Pinned
    /// so that accepting such a host again is a decision, not a side effect.
    ///
    /// Revert-check: the same revert as `testPercentEncodedNonASCIIHost_isBlocked` makes this
    /// fail.
    func testPercentEncodedPublicName_isBlocked() {
        assertBlocked("https://b%C3%BCcher.example.com/")
    }

    // MARK: - Malformed URLs

    func testEmptyHost_isBlocked() {
        // file:// has no host; we return true (i.e., block) to fail closed.
        if let url = URL(string: "file:///etc/passwd") {
            XCTAssertTrue(PrivateNetworkAddressDetector.isPrivateOrReserved(url))
        }
    }

    // MARK: - Helpers

    private func assertAllowed(_ urlString: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = URL(string: urlString) else {
            XCTFail("Could not parse URL: \(urlString)", file: file, line: line)
            return
        }
        XCTAssertFalse(
            PrivateNetworkAddressDetector.isPrivateOrReserved(url),
            "Expected \(urlString) to be allowed, but it was blocked",
            file: file,
            line: line
        )
    }

    private func assertBlocked(_ urlString: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = URL(string: urlString) else {
            XCTFail("Could not parse URL: \(urlString)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            PrivateNetworkAddressDetector.isPrivateOrReserved(url),
            "Expected \(urlString) to be blocked, but it was allowed",
            file: file,
            line: line
        )
    }
}
