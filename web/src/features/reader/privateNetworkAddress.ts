// Classifies hosts that refer to private, loopback, link-local or otherwise
// reserved network addresses. Port of
// esc-chatmail/Services/Security/PrivateNetworkAddressDetector.swift, which on
// iOS refuses email link activations into the user's LAN
// (FullInteractiveEmailWebView.navigationDecision → .blockedPrivateNetwork).
//
// Performs only local classification on literal IPs and reserved hostnames. A
// sender can still name a public host that resolves to an internal address;
// the browser, not this module, is what stands between a click and that
// request.

const RESERVED_HOSTNAMES = new Set([
  'localhost',
  'localhost.localdomain',
  'broadcasthost',
  'ip6-localhost',
  'ip6-loopback',
  'ip6-localnet',
  'ip6-mcastprefix',
  'ip6-allnodes',
  'ip6-allrouters',
  'ip6-allhosts',
])

// RFC 6761 / RFC 6762 / RFC 8375 — not resolvable to routable public
// addresses. `.onion` (Tor) is included because resolving it through the
// default resolver leaks the query.
const RESERVED_TLDS = new Set([
  'local',
  'localhost',
  'lan',
  'intranet',
  'internal',
  'private',
  'corp',
  'home',
  'test',
  'invalid',
  'example',
  'onion',
])

/** Classifies a parsed URL by its host; `url.hostname` keeps IPv6 brackets. */
export function isPrivateOrReservedUrl(url: URL): boolean {
  return isPrivateOrReservedHost(url.hostname)
}

/**
 * Returns true if the host refers to a reserved or private network address
 * that an untrusted link should not be allowed to reach. Fails closed on an
 * empty host, a scoped IPv6 literal and a single-label name.
 */
export function isPrivateOrReservedHost(rawHost: string): boolean {
  let host = rawHost.trim().toLowerCase()
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1)
  if (host.length === 0) return true

  if (RESERVED_HOSTNAMES.has(host)) return true

  // Empty labels are skipped so "localhost." classifies by its real TLD, as
  // Swift's split(separator:) omits empty subsequences.
  const labels = host.split('.').filter((label) => label.length > 0)
  const tld = labels[labels.length - 1]
  if (tld !== undefined && RESERVED_TLDS.has(tld)) return true

  const ipv4 = ipv4FromAnyForm(host)
  if (ipv4 !== null) return isPrivateIPv4(ipv4)

  // Scoped IPv6 literals include a zone identifier (for example "%en0").
  // inet_pton rejects that syntax, so fail closed instead of falling through
  // to "public" for local-only addresses like "fe80::1%25en0" or "::1%25lo0".
  if (host.includes(':') && host.includes('%')) return true

  const ipv6 = ipv6AddressBytes(host)
  if (ipv6 !== null) return isPrivateIPv6(ipv6)

  // Single-label hostnames (no dots, not recognizable as an IP) are not
  // routable on the public Internet. Block defensively — a legitimate
  // email CDN always uses a fully qualified domain.
  if (!host.includes('.') && !host.includes(':')) return true

  return false
}

// MARK: - IPv4

/**
 * Accepts canonical dotted-decimal, plus the legacy octal / hexadecimal /
 * integer forms that resolvers still accept (inet_aton semantics: 1–4 parts,
 * the last one filling the remaining bytes, "0177.0.0.1" → 127.0.0.1). The
 * WHATWG URL parser already canonicalizes these before `hostname` is read,
 * so this matters for callers classifying a raw host string.
 */
function ipv4FromAnyForm(host: string): number | null {
  const parts = host.split('.')
  if (parts.length === 0 || parts.length > 4) return null

  const values: number[] = []
  for (const part of parts) {
    const value = parseInetAtonPart(part)
    if (value === null) return null
    values.push(value)
  }

  const last = values[values.length - 1]
  if (last === undefined) return null
  const leading = values.slice(0, -1)
  if (leading.some((value) => value > 0xff)) return null
  const lastWidthBits = (4 - leading.length) * 8
  if (lastWidthBits < 32 && last > 2 ** lastWidthBits - 1) return null
  if (last > 0xffffffff) return null

  let address = 0
  for (const value of leading) address = (address << 8) | value
  address = address * 2 ** lastWidthBits + last
  return address >>> 0
}

function parseInetAtonPart(part: string): number | null {
  if (/^0x[0-9a-f]*$/.test(part)) {
    // "0x" with no digits is zero to inet_aton and the WHATWG parser alike.
    return part.length === 2 ? 0 : Number.parseInt(part.slice(2), 16)
  }
  if (/^0[0-7]*$/.test(part)) {
    return part.length === 1 ? 0 : Number.parseInt(part.slice(1), 8)
  }
  if (/^[1-9][0-9]*$/.test(part)) {
    return Number.parseInt(part, 10)
  }
  return null
}

/** Network and mask in host byte order. */
const PRIVATE_IPV4_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x00000000, 0xff000000], // 0.0.0.0/8         "this network"
  [0x0a000000, 0xff000000], // 10.0.0.0/8        private
  [0x64400000, 0xffc00000], // 100.64.0.0/10     CGNAT
  [0x7f000000, 0xff000000], // 127.0.0.0/8       loopback
  [0xa9fe0000, 0xffff0000], // 169.254.0.0/16    link-local (incl. 169.254.169.254 metadata)
  [0xac100000, 0xfff00000], // 172.16.0.0/12     private
  [0xc0000000, 0xfffffff8], // 192.0.0.0/29      protocol assignments
  [0xc0000200, 0xffffff00], // 192.0.2.0/24      TEST-NET-1
  [0xc0a80000, 0xffff0000], // 192.168.0.0/16    private
  [0xc6120000, 0xfffe0000], // 198.18.0.0/15     benchmarking
  [0xc6336400, 0xffffff00], // 198.51.100.0/24   TEST-NET-2
  [0xcb007100, 0xffffff00], // 203.0.113.0/24    TEST-NET-3
  [0xe0000000, 0xf0000000], // 224.0.0.0/4       multicast
  [0xf0000000, 0xf0000000], // 240.0.0.0/4       reserved
  [0xffffffff, 0xffffffff], // 255.255.255.255   limited broadcast
]

function isPrivateIPv4(address: number): boolean {
  return PRIVATE_IPV4_RANGES.some(([network, mask]) => (address & mask) >>> 0 === network)
}

// MARK: - IPv6

const IPV6_GROUP_PATTERN = /^[0-9a-f]{1,4}$/
const STRICT_IPV4_PART_PATTERN = /^(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/

/** inet_pton(AF_INET6) semantics: at most one "::", an optional dotted-decimal tail. */
function ipv6AddressBytes(host: string): Uint8Array | null {
  const gap = host.indexOf('::')
  if (gap !== -1 && host.indexOf('::', gap + 1) !== -1) return null

  const left = gap === -1 ? host : host.slice(0, gap)
  const right = gap === -1 ? null : host.slice(gap + 2)
  const leftGroups = ipv6Groups(left)
  const rightGroups = right === null ? [] : ipv6Groups(right)
  if (leftGroups === null || rightGroups === null) return null

  let groups: number[]
  if (gap === -1) {
    if (leftGroups.length !== 8) return null
    groups = leftGroups
  } else {
    if (leftGroups.length + rightGroups.length > 7) return null
    const fill = 8 - leftGroups.length - rightGroups.length
    groups = [...leftGroups, ...new Array<number>(fill).fill(0), ...rightGroups]
  }

  const bytes = new Uint8Array(16)
  groups.forEach((group, index) => {
    bytes[index * 2] = group >>> 8
    bytes[index * 2 + 1] = group & 0xff
  })
  return bytes
}

function ipv6Groups(text: string): number[] | null {
  if (text.length === 0) return []
  const parts = text.split(':')
  const groups: number[] = []
  for (const [index, part] of parts.entries()) {
    if (index === parts.length - 1 && part.includes('.')) {
      const embedded = strictDottedDecimal(part)
      if (embedded === null) return null
      groups.push(embedded >>> 16, embedded & 0xffff)
    } else if (IPV6_GROUP_PATTERN.test(part)) {
      groups.push(Number.parseInt(part, 16))
    } else {
      return null
    }
  }
  return groups
}

function strictDottedDecimal(text: string): number | null {
  const parts = text.split('.')
  if (parts.length !== 4 || !parts.every((part) => STRICT_IPV4_PART_PATTERN.test(part))) {
    return null
  }
  let address = 0
  for (const part of parts) address = (address << 8) | Number.parseInt(part, 10)
  return address >>> 0
}

function isPrivateIPv6(bytes: Uint8Array): boolean {
  if (bytes.length !== 16) return true

  // :: unspecified
  if (bytes.every((byte) => byte === 0)) return true

  // ::1 loopback
  if (bytes.subarray(0, 15).every((byte) => byte === 0) && bytes[15] === 1) return true

  const first = bytes[0] ?? 0
  const second = bytes[1] ?? 0

  // fc00::/7 Unique Local Addresses
  if ((first & 0xfe) === 0xfc) return true

  // fe80::/10 link-local
  if (first === 0xfe && (second & 0xc0) === 0x80) return true

  // ff00::/8 multicast
  if (first === 0xff) return true

  // IPv4-mapped ::ffff:0:0/96 — classify by the embedded IPv4 address.
  if (
    bytes.subarray(0, 10).every((byte) => byte === 0) &&
    bytes[10] === 0xff &&
    bytes[11] === 0xff
  ) {
    return isPrivateIPv4(embeddedIPv4(bytes))
  }

  // IPv4-compatible ::/96 (deprecated but still seen in the wild).
  if (bytes.subarray(0, 12).every((byte) => byte === 0)) {
    return isPrivateIPv4(embeddedIPv4(bytes))
  }

  return false
}

function embeddedIPv4(bytes: Uint8Array): number {
  return (
    (((bytes[12] ?? 0) << 24) |
      ((bytes[13] ?? 0) << 16) |
      ((bytes[14] ?? 0) << 8) |
      (bytes[15] ?? 0)) >>>
    0
  )
}
