import Darwin
import Foundation

/// Classifies URLs that target private, loopback, link-local, or otherwise
/// reserved network addresses — used to block SSRF against URLs that come from
/// attacker-controlled email content (image fetches, link-preview fetches).
///
/// Performs only local classification on literal IPs and reserved hostnames.
/// A malicious sender can still supply a public hostname that resolves to an
/// internal address, so callers should pair this with
/// `SSRFGuardingURLSession` to also block redirects to private destinations.
enum PrivateNetworkAddressDetector {
    /// Returns true if the URL's host refers to a reserved or private network
    /// address that an untrusted fetch should not be allowed to reach.
    static func isPrivateOrReserved(_ url: URL) -> Bool {
        guard let host = classifiableHost(of: url) else {
            return true
        }

        if reservedHostnames.contains(host) {
            return true
        }

        if let tld = host.split(separator: ".").last.map(String.init),
           reservedTLDs.contains(tld) {
            return true
        }

        // A host can have two IPv4 readings (`ipv4Readings(of:)`). One private reading is enough
        // to refuse it, because the detector cannot know which one the consumer applies.
        let readings = ipv4Readings(of: host)
        if !readings.isEmpty {
            return readings.contains(where: isPrivateIPv4)
        }

        // Scoped IPv6 literals include a zone identifier (for example
        // "%en0"). `inet_pton` rejects that syntax, so fail closed instead of
        // falling through to "public" for local-only addresses like
        // "[fe80::1%25en0]" or "[::1%25lo0]".
        if host.contains(":") && host.contains("%") {
            return true
        }

        if let ipv6 = ipv6AddressBytes(host) {
            return isPrivateIPv6(ipv6)
        }

        // Single-label hostnames (no dots, not recognizable as an IP) are not
        // routable on the public Internet. Block defensively — a legitimate
        // email CDN always uses a fully qualified domain.
        if !host.contains(".") && !host.contains(":") {
            return true
        }

        return false
    }

    /// The lowercased host to classify, or nil when the URL has no usable host and must be
    /// refused.
    ///
    /// A host that is not ASCII is refused. Measured on the iOS 27.0 simulator, for `URL(string:)`
    /// and for a URL bridged from `NSURL`:
    /// - Foundation maps a non-ASCII host written as such to its ASCII form when it parses the URL
    ///   (`bücher.example.com` arrives as `xn--bcher-kva.example.com`, `１２７.0.0.1` as
    ///   `127.0.0.1`), so the only non-ASCII host that reaches here was percent-encoded in the URL,
    ///   which Foundation leaves alone.
    /// - WebKit decodes and maps such a host when it opens the URL, and the checks below cannot
    ///   read what it will become: `192.168.0.1%EF%BC%8E` (a fullwidth full stop) arrives as
    ///   `192.168.0.1．` and `%EF%BC%91%EF%BC%92%EF%BC%97.0.0.1` as `１２７.0.0.1`, both were classed
    ///   public, and WebKit's URL parser reads them as `192.168.0.1` and `127.0.0.1`.
    ///
    /// An unwrapped Amazon SES destination is where this reached a click. The cost is that a public
    /// name whose host is percent-encoded (`b%C3%BCcher.example.com`) is refused too.
    ///
    /// One trailing dot is then dropped. It only marks a name as fully qualified, but the address
    /// and single-label checks below read it as part of the name: `inet_aton` rejects
    /// `192.168.0.1.`, and `printer.` no longer looks like a single label, so both fell through to
    /// "public" while the URL still reached the private host. Measured on the same simulator:
    /// WebKit's URL parser turns `http://192.168.0.1./` into the host `192.168.0.1` (and `127.1.`,
    /// `2130706433.`, `0x7f.1.` and `0177.0.0.1.` into `127.0.0.1`), and
    /// `getaddrinfo("192.168.0.1.")` resolves to 192.168.0.1. Foundation hands over the same dotted
    /// host for `192.168.0.1%2E` and for an ideographic full stop written as such
    /// (`192.168.0.1。`).
    ///
    /// A host that is empty or still ends in a dot after that (`.`, `192.168.0.1..`) has an empty
    /// label. On the same simulator WebKit kept such a host as a name and `getaddrinfo` failed on
    /// it, so it is refused rather than guessed at.
    private static func classifiableHost(of url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }

        guard host.unicodeScalars.allSatisfy(\.isASCII) else {
            return nil
        }

        if host.hasSuffix(".") {
            host.removeLast()
        }

        guard !host.isEmpty, !host.hasSuffix(".") else {
            return nil
        }

        return host
    }

    // MARK: - Reserved names

    private static let reservedHostnames: Set<String> = [
        "localhost",
        "localhost.localdomain",
        "broadcasthost",
        "ip6-localhost",
        "ip6-loopback",
        "ip6-localnet",
        "ip6-mcastprefix",
        "ip6-allnodes",
        "ip6-allrouters",
        "ip6-allhosts"
    ]

    // RFC 6761 / RFC 6762 / RFC 8375 — not resolvable to routable public
    // addresses. `.onion` (Tor) is included because resolving it through the
    // default resolver leaks the query.
    private static let reservedTLDs: Set<String> = [
        "local",
        "localhost",
        "lan",
        "intranet",
        "internal",
        "private",
        "corp",
        "home",
        "test",
        "invalid",
        "example",
        "onion"
    ]

    // MARK: - IPv4

    /// Every IPv4 address this host can be read as, in host byte order. Empty when it is not an
    /// IPv4 literal in any form.
    ///
    /// The readings disagree on a dotted quad with a leading-zero part, and each one is what some
    /// consumer applies (measured on the iOS 27.0 simulator):
    /// - `inet_aton` reads the part as octal, and also accepts the hexadecimal, integer and short
    ///   forms. WebKit's URL parser reads a host the same way: `0177.0.0.1` is 127.0.0.1 and
    ///   `0127.0.0.1` is 87.0.0.1.
    /// - The system resolver reads every part of a dotted quad as decimal, as Darwin's `inet_pton`
    ///   does: `getaddrinfo("0177.0.0.1")` is 177.0.0.1 and `getaddrinfo("0127.0.0.1")` is
    ///   127.0.0.1.
    ///
    /// Returning only the `inet_aton` reading classed `010.0.0.1`, `0127.0.0.1`, `172.016.0.1` and
    /// `169.0254.169.254` as public (8.0.0.1, 87.0.0.1, 172.14.0.1, 169.172.169.254) while a
    /// `URLSession` request for `http://0127.0.0.1:<port>/` reached a loopback listener.
    private static func ipv4Readings(of host: String) -> [UInt32] {
        var readings: [UInt32] = []

        var addr = in_addr()
        if inet_aton(host, &addr) != 0 {
            readings.append(UInt32(bigEndian: addr.s_addr))
        }

        if let decimal = dottedDecimalIPv4(host) {
            readings.append(decimal)
        }

        return readings
    }

    /// The address a dotted quad names when every part is read as decimal, leading zeros included
    /// (`010.0.0.1` is 10.0.0.1), or nil when the host is not four decimal parts of at most 255.
    ///
    /// Darwin's `inet_pton(AF_INET)` read every host tried this way on the iOS 27.0 simulator. The
    /// rule is spelled out here so that the decimal reading is always considered, whether or not a
    /// given libc's `inet_pton` tolerates leading zeros.
    private static func dottedDecimalIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }

        var address: UInt32 = 0
        for part in parts {
            guard !part.isEmpty else {
                return nil
            }

            var value: UInt32 = 0
            for byte in part.utf8 {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    return nil
                }
                value = value * 10 + UInt32(byte - UInt8(ascii: "0"))
                guard value <= 255 else {
                    return nil
                }
            }
            address = (address << 8) | value
        }

        return address
    }

    private static func isPrivateIPv4(_ addr: UInt32) -> Bool {
        // (network, mask) in host byte order.
        let ranges: [(UInt32, UInt32)] = [
            (0x00000000, 0xFF000000),   // 0.0.0.0/8         "this network"
            (0x0A000000, 0xFF000000),   // 10.0.0.0/8        private
            (0x64400000, 0xFFC00000),   // 100.64.0.0/10     CGNAT
            (0x7F000000, 0xFF000000),   // 127.0.0.0/8       loopback
            (0xA9FE0000, 0xFFFF0000),   // 169.254.0.0/16    link-local (incl. 169.254.169.254 metadata)
            (0xAC100000, 0xFFF00000),   // 172.16.0.0/12     private
            (0xC0000000, 0xFFFFFFF8),   // 192.0.0.0/29      protocol assignments
            (0xC0000200, 0xFFFFFF00),   // 192.0.2.0/24      TEST-NET-1
            (0xC0A80000, 0xFFFF0000),   // 192.168.0.0/16    private
            (0xC6120000, 0xFFFE0000),   // 198.18.0.0/15     benchmarking
            (0xC6336400, 0xFFFFFF00),   // 198.51.100.0/24   TEST-NET-2
            (0xCB007100, 0xFFFFFF00),   // 203.0.113.0/24    TEST-NET-3
            (0xE0000000, 0xF0000000),   // 224.0.0.0/4       multicast
            (0xF0000000, 0xF0000000),   // 240.0.0.0/4       reserved
            (0xFFFFFFFF, 0xFFFFFFFF)    // 255.255.255.255   limited broadcast
        ]

        for (network, mask) in ranges where (addr & mask) == network {
            return true
        }
        return false
    }

    // MARK: - IPv6

    private static func ipv6AddressBytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, host, &addr) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }

        // :: unspecified
        if bytes.allSatisfy({ $0 == 0 }) {
            return true
        }

        // ::1 loopback
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return true
        }

        // fc00::/7 Unique Local Addresses
        if bytes[0] & 0xFE == 0xFC {
            return true
        }

        // fe80::/10 link-local
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
            return true
        }

        // ff00::/8 multicast
        if bytes[0] == 0xFF {
            return true
        }

        // IPv4-mapped ::ffff:0:0/96 — classify by the embedded IPv4 address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }),
           bytes[10] == 0xFF,
           bytes[11] == 0xFF {
            return isPrivateIPv4(embeddedIPv4(bytes))
        }

        // IPv4-compatible ::/96 (deprecated but still seen in the wild).
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isPrivateIPv4(embeddedIPv4(bytes))
        }

        return false
    }

    private static func embeddedIPv4(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[12]) << 24) |
        (UInt32(bytes[13]) << 16) |
        (UInt32(bytes[14]) << 8)  |
         UInt32(bytes[15])
    }
}
