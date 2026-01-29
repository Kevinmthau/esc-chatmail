import Foundation

/// Handles URL sanitization within HTML content
struct HTMLURLSanitizer {
    private static let allowedProtocols: Set<String> = [
        "http", "https", "mailto", "tel"
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

    private static let dataURLRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "^data:image\\/(png|jpeg|jpg|gif|webp|bmp|svg\\+xml|x-icon|vnd\\.microsoft\\.icon)(;base64)?,",
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

    /// Sanitizes href and src attributes in HTML
    func sanitizeURLs(_ html: String) -> String {
        var result = html

        // Sanitize href attributes
        result = sanitizeHrefAttributes(result)

        // Sanitize src attributes
        result = sanitizeSrcAttributes(result)

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

    private func sanitizeSrcAttributes(_ html: String) -> String {
        var result = html
        let srcMatches = Self.srcRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        let transparentPixel = "src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\""

        for match in srcMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let url = String(result[range]).trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip empty URLs but don't replace valid newsletter tracking pixels
                if url.isEmpty {
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: transparentPixel)
                } else if url.hasPrefix("javascript:") || url.hasPrefix("vbscript:") {
                    // Only block explicitly dangerous URLs
                    guard let fullRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(fullRange, with: transparentPixel)
                }
                // cid: URLs are preserved - they'll be handled by CIDSchemeHandler
                // Allow all other URLs including tracking pixels and newsletter images
            }
        }

        return result
    }

    /// Checks if a URL is safe to include
    func isURLSafe(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Block javascript: and vbscript: URLs
        if trimmed.hasPrefix("javascript:") || trimmed.hasPrefix("vbscript:") {
            return false
        }

        // Allow data URLs for images only
        if trimmed.hasPrefix("data:") {
            return isDataURL(trimmed)
        }

        // Check if URL starts with allowed protocol
        for proto in Self.allowedProtocols {
            if trimmed.hasPrefix("\(proto)://") || trimmed.hasPrefix("\(proto):") {
                return true
            }
        }

        // Allow relative URLs
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("#") || trimmed.hasPrefix("?") {
            return true
        }

        // Allow URLs without protocol (will be treated as relative)
        if !trimmed.contains(":") {
            return true
        }

        return false
    }

    /// Validates that a data URL is a safe image format
    func isDataURL(_ url: String) -> Bool {
        return Self.dataURLRegex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
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
