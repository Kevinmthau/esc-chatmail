import Foundation

/// Handles URL sanitization within HTML content
struct HTMLURLSanitizer {
    private static let allowedProtocols: Set<String> = [
        "http", "https", "mailto", "tel"
    ]

    /// Sanitizes href and src attributes in HTML
    func sanitizeURLs(_ html: String) -> String {
        var result = html

        // Sanitize href attributes
        result = sanitizeHrefAttributes(result)

        // Sanitize src attributes
        result = sanitizeSrcAttributes(result)

        return result
    }

    private func sanitizeHrefAttributes(_ html: String) -> String {
        var result = html
        let hrefPattern = "href\\s*=\\s*[\"']([^\"']*)[\"']"
        let hrefRegex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive)
        let matches = hrefRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []

        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let url = String(result[range])
                if !isURLSafe(url) {
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: "href=\"#\"")
                }
            }
        }

        return result
    }

    private func sanitizeSrcAttributes(_ html: String) -> String {
        var result = html
        let srcPattern = "src\\s*=\\s*[\"']([^\"']*)[\"']"
        let srcRegex = try? NSRegularExpression(pattern: srcPattern, options: .caseInsensitive)
        let srcMatches = srcRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []

        let transparentPixel = "src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\""

        for match in srcMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let url = String(result[range]).trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip empty URLs but don't replace valid newsletter tracking pixels
                if url.isEmpty {
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: transparentPixel)
                } else if url.hasPrefix("javascript:") || url.hasPrefix("vbscript:") {
                    // Only block explicitly dangerous URLs
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: transparentPixel)
                } else if url.hasPrefix("cid:") {
                    // Replace cid: (Content-ID) URLs with transparent placeholder
                    // These are inline email attachments that WKWebView can't load directly
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: transparentPixel)
                }
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
        let safeDataURLPattern = "^data:image\\/(png|jpeg|jpg|gif|webp|bmp|svg\\+xml|x-icon|vnd\\.microsoft\\.icon)(;base64)?,"
        return url.range(of: safeDataURLPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
