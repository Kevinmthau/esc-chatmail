import Foundation

/// Handles URL sanitization within HTML content
struct HTMLURLSanitizer {
    private static let allowedProtocols: Set<String> = [
        "http", "https", "mailto", "tel", "cid"
    ]

    /// Dangerous protocols that should always be blocked
    private static let dangerousProtocols: Set<String> = [
        "javascript", "vbscript", "data"  // data: handled separately for images
    ]

    // Cached compiled regex patterns for performance
    // These patterns are compile-time constants; failure indicates programmer error
    private static let hrefRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "href\\s*=\\s*[\"']([^\"']*)[\"']",
            options: .caseInsensitive
        )
    }()

    private static let srcRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "src\\s*=\\s*[\"']([^\"']*)[\"']",
            options: .caseInsensitive
        )
    }()

    private static let modernImageFormatQueryHints: [(key: String, riskyValues: Set<String>, replacement: String)] = [
        ("format", ["auto", "avif", "webp"], "jpeg"),
        ("fm", ["avif", "webp"], "jpg")
    ]

    // Safe image MIME types for data URLs (excludes SVG which can contain scripts)
    private static let dataURLRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "^data:image\\/(png|jpeg|jpg|gif|webp|bmp|x-icon|vnd\\.microsoft\\.icon)(;base64)?,",
            options: .caseInsensitive
        )
    }()

    /// Regex to match Cloudflare cdn-cgi image URLs with format=auto
    /// These URLs can return AVIF which iOS may fail to decode
    private static let cloudflareCDNRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(/cdn-cgi/image/[^"']*?)format=auto([^"']*)"#,
            options: []
        )
    }()

    // Pre-compiled regex for HTML entity decoding (performance optimization)
    // swiftlint:disable:next force_try
    private static let decimalEntityRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "&#(\\d+);", options: .caseInsensitive)
    }()

    // swiftlint:disable:next force_try
    private static let hexEntityRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: .caseInsensitive)
    }()

    /// Sanitizes href and src attributes in HTML
    func sanitizeURLs(_ html: String, rewriteModernFormatQueryHints: Bool = true) -> String {
        var result = html

        // Sanitize href attributes
        result = sanitizeHrefAttributes(result)

        // Sanitize src attributes
        result = sanitizeSrcAttributes(
            result,
            rewriteModernFormatQueryHints: rewriteModernFormatQueryHints
        )

        // Rewrite Cloudflare CDN image URLs to avoid AVIF decoding issues
        result = rewriteCloudflareCDNImageURLs(result)

        return result
    }

    private func sanitizeHrefAttributes(_ html: String) -> String {
        var result = html
        let matches = Self.hrefRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let url = String(result[range])
                if !isURLSafe(url) {
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: "href=\"#\"")
                }
            }
        }

        return result
    }

    private func sanitizeSrcAttributes(_ html: String, rewriteModernFormatQueryHints: Bool) -> String {
        var result = html
        let srcMatches = Self.srcRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        let transparentPixel = "src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\""

        for match in srcMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let url = String(result[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                let decodedURL = HTMLEntityDecoder.decode(url)

                // Skip empty URLs
                if url.isEmpty {
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: transparentPixel)
                    continue
                }

                // Normalize URL to catch bypass attempts
                let normalized = normalizeURL(decodedURL)

                // Block dangerous protocols (javascript:, vbscript:, and unsafe data: URLs)
                if normalized.hasPrefix("javascript:") || normalized.hasPrefix("vbscript:") {
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: transparentPixel)
                } else if normalized.hasPrefix("data:") && !isDataURL(normalized) {
                    // Block non-image data URLs (e.g., data:text/html)
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: transparentPixel)
                } else if rewriteModernFormatQueryHints,
                          let rewrittenURL = rewriteModernImageFormatHints(in: decodedURL),
                          rewrittenURL != decodedURL,
                          let fullRange = Range(match.range, in: result) {
                    let escapedURL = htmlAttributeEscaped(rewrittenURL)
                    result.replaceSubrange(fullRange, with: "src=\"\(escapedURL)\"")
                }
                // cid: URLs are preserved - they'll be handled by CIDSchemeHandler
                // Allow all other URLs including tracking pixels and newsletter images
            }
        }

        return result
    }

    /// Normalizes a URL by decoding percent-encoding, HTML entities, and removing control characters
    /// This prevents bypass attempts like `java%73cript:` or `&#106;avascript:`
    private func normalizeURL(_ url: String) -> String {
        var result = url

        // Step 1: Decode percent-encoding (may need multiple passes for double-encoding)
        var previousResult = ""
        var iterations = 0
        while previousResult != result && iterations < 3 {
            previousResult = result
            if let decoded = result.removingPercentEncoding {
                result = decoded
            }
            iterations += 1
        }

        // Step 2: Decode HTML entities (numeric and named)
        result = decodeHTMLEntities(result)

        // Step 3: Remove whitespace and control characters within protocol portion
        // This prevents bypasses like "java\nscript:" or "java\tscript:"
        result = removeControlCharactersFromProtocol(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Decodes HTML entities in URL strings
    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        // Decode numeric entities (&#106; -> j, &#x6A; -> j)
        // Decimal entities
        let decimalRange = NSRange(result.startIndex..., in: result)
        let decimalMatches = Self.decimalEntityRegex.matches(in: result, range: decimalRange)
        for match in decimalMatches.reversed() {
            if let codeRange = Range(match.range(at: 1), in: result),
               let fullRange = Range(match.range, in: result),
               let codePoint = Int(result[codeRange]),
               let scalar = Unicode.Scalar(codePoint) {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        // Hex entities (&#x6A; -> j)
        let hexRange = NSRange(result.startIndex..., in: result)
        let hexMatches = Self.hexEntityRegex.matches(in: result, range: hexRange)
        for match in hexMatches.reversed() {
            if let codeRange = Range(match.range(at: 1), in: result),
               let fullRange = Range(match.range, in: result),
               let codePoint = Int(result[codeRange], radix: 16),
               let scalar = Unicode.Scalar(codePoint) {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }

    /// Removes control characters and whitespace from the protocol portion of a URL
    private func removeControlCharactersFromProtocol(_ url: String) -> String {
        // Find the colon that separates protocol from the rest
        guard let colonIndex = url.firstIndex(of: ":") else {
            return url
        }

        // Extract and clean the protocol portion
        let protocolPart = url[..<colonIndex]
        let cleanProtocol = protocolPart.filter { char in
            // Only allow alphanumeric characters in protocol
            char.isLetter || char.isNumber
        }

        let rest = url[colonIndex...]
        return String(cleanProtocol) + String(rest)
    }

    /// Checks if a URL is safe to include
    func isURLSafe(_ url: String) -> Bool {
        // Normalize URL to prevent bypass attempts
        let normalized = normalizeURL(url)

        // Extract protocol from normalized URL
        if let colonIndex = normalized.firstIndex(of: ":") {
            let proto = String(normalized[..<colonIndex])

            // Block dangerous protocols
            if Self.dangerousProtocols.contains(proto) {
                // Special case: allow data: URLs for images only
                if proto == "data" {
                    return isDataURL(normalized)
                }
                return false
            }

            // Allow known safe protocols
            if Self.allowedProtocols.contains(proto) {
                return true
            }

            // Block unknown protocols
            return false
        }

        // Allow relative URLs
        if normalized.hasPrefix("/") || normalized.hasPrefix("#") || normalized.hasPrefix("?") {
            return true
        }

        // Allow URLs without protocol (will be treated as relative)
        if !normalized.contains(":") {
            return true
        }

        return false
    }

    /// Validates that a data URL is a safe image format
    func isDataURL(_ url: String) -> Bool {
        return Self.dataURLRegex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    private func rewriteModernImageFormatHints(in urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return nil
        }

        var rewrittenItems = queryItems
        var didRewrite = false

        for index in rewrittenItems.indices {
            guard let rawValue = rewrittenItems[index].value?.lowercased() else {
                continue
            }

            for hint in Self.modernImageFormatQueryHints where rewrittenItems[index].name.caseInsensitiveCompare(hint.key) == .orderedSame {
                if hint.riskyValues.contains(rawValue) {
                    rewrittenItems[index].value = hint.replacement
                    didRewrite = true
                }
            }
        }

        guard didRewrite else { return nil }

        var rewrittenComponents = components
        rewrittenComponents.queryItems = rewrittenItems
        return rewrittenComponents.string
    }

    private func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Rewrites Cloudflare cdn-cgi image URLs to use JPEG format instead of auto
    ///
    /// Cloudflare's image resizing service (`/cdn-cgi/image/`) with `format=auto` can return
    /// AVIF images when the browser advertises support. WKWebView advertises AVIF support,
    /// but iOS fails to decode some AVIF images with error: `'AVIF'-_reader->initImage[0] failed`
    ///
    /// This method replaces `format=auto` with `format=jpeg` for reliable image rendering.
    private func rewriteCloudflareCDNImageURLs(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        return Self.cloudflareCDNRegex.stringByReplacingMatches(
            in: html,
            options: [],
            range: range,
            withTemplate: "$1format=jpeg$2"
        )
    }
}
