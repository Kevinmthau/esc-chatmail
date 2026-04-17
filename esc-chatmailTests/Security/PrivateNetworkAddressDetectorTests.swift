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
