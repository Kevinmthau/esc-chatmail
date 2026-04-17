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
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return true
        }

        if reservedHostnames.contains(host) {
            return true
        }

        if let tld = host.split(separator: ".").last.map(String.init),
           reservedTLDs.contains(tld) {
            return true
        }

        if let ipv4 = ipv4FromAnyForm(host) {
            return isPrivateIPv4(ipv4)
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

    /// Accepts canonical dotted-decimal, plus the legacy octal / hexadecimal /
    /// integer forms that `getaddrinfo` still resolves. `inet_aton` runs first
    /// because it matches the resolver's interpretation for leading-zero
    /// octets (e.g. "0177.0.0.1" → 127.0.0.1); `inet_pton` would otherwise
    /// parse that as decimal 177 and let loopback through.
    private static func ipv4FromAnyForm(_ host: String) -> UInt32? {
        var addr = in_addr()

        if inet_aton(host, &addr) != 0 {
            return UInt32(bigEndian: addr.s_addr)
        }

        if inet_pton(AF_INET, host, &addr) == 1 {
            return UInt32(bigEndian: addr.s_addr)
        }

        return nil
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
