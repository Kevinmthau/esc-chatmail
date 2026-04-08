import Foundation

/// Removes tracking pixels and known tracking elements from HTML
struct HTMLTrackingRemover {
    // Known tracking service domains (full domain match)
    private static let trackingDomains = [
        "googleadservices.com",
        "doubleclick.net",
        "google-analytics.com",
        "googlesyndication.com",
        "facebook.com/tr",
        "bat.bing.com",
        "t.co/i/",           // Twitter tracking pixel
        "linkedin.com/px",   // LinkedIn tracking pixel
        "mc.yandex.ru",      // Yandex Metrica
        "ct.pinterest.com",  // Pinterest
        "snap.licdn.com"     // LinkedIn
    ]

    // Tracking subdomain patterns (match at domain boundary)
    private static let trackingSubdomains = [
        "analytics",
        "tracking",
        "pixel",
        "beacon",
        "metrics",
        "telemetry",
        "track"
    ]

    // Common tracking pixel filenames
    private static let trackingFilenames = [
        "pixel.gif",
        "spacer.gif",
        "blank.gif",
        "1x1.gif",
        "transparent.gif",
        "t.gif",
        "pixel.png",
        "open.gif",
        "tracker.gif",
        "o.gif"
    ]

    // Pre-compiled regex for 1x1 pixels by attribute
    // swiftlint:disable:next force_try
    private static let pixelByAttributeRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<img[^>]*(?:width\\s*=\\s*[\"']1[\"']\\s+height\\s*=\\s*[\"']1[\"']|height\\s*=\\s*[\"']1[\"']\\s+width\\s*=\\s*[\"']1[\"'])[^>]*>",
            options: .caseInsensitive
        )
    }()

    // Pre-compiled regex for CSS-sized 1x1 pixels
    // swiftlint:disable:next force_try
    private static let pixelByCSSRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<img[^>]*style\\s*=\\s*[\"'][^\"']*(?:width\\s*:\\s*1px[^\"']*height\\s*:\\s*1px|height\\s*:\\s*1px[^\"']*width\\s*:\\s*1px)[^\"']*[\"'][^>]*>",
            options: .caseInsensitive
        )
    }()

    // Pre-compiled regex patterns for tracking domains (performance optimization)
    private static let trackingDomainPatterns: [NSRegularExpression] = {
        trackingDomains.compactMap { domain in
            let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*\(escapedDomain)[^\"']*[\"'][^>]*>"
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }()

    // Pre-compiled regex patterns for tracking subdomains
    private static let trackingSubdomainPatterns: [NSRegularExpression] = {
        trackingSubdomains.compactMap { subdomain in
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*(?://|\\.)\(subdomain)\\.[^\"']*[\"'][^>]*>"
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }()

    // Pre-compiled regex patterns for tracking filenames
    private static let trackingFilenamePatterns: [NSRegularExpression] = {
        trackingFilenames.compactMap { filename in
            let escapedFilename = NSRegularExpression.escapedPattern(for: filename)
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*/\(escapedFilename)[^\"']*[\"'][^>]*>"
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }()

    /// Removes tracking pixels from HTML content
    func removeTrackingPixels(_ html: String) -> String {
        var result = html

        // Remove 1x1 images by width/height attributes
        let range1 = NSRange(result.startIndex..., in: result)
        result = Self.pixelByAttributeRegex.stringByReplacingMatches(in: result, range: range1, withTemplate: "")

        // Remove 1x1 images by CSS style
        let range2 = NSRange(result.startIndex..., in: result)
        result = Self.pixelByCSSRegex.stringByReplacingMatches(in: result, range: range2, withTemplate: "")

        // Remove images from known tracking domains (using pre-compiled patterns)
        for regex in Self.trackingDomainPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove images from tracking subdomains (using pre-compiled patterns)
        for regex in Self.trackingSubdomainPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove images with common tracking filenames (using pre-compiled patterns)
        for regex in Self.trackingFilenamePatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result
    }

    /// Shared tracking heuristics for image URLs that may be surfaced outside the HTML render path.
    func isTrackingLikeImageURL(_ urlString: String) -> Bool {
        let normalized = urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else {
            return true
        }

        let components = URLComponents(string: normalized)
        let host = components?.host?.lowercased()
        let path = components?.path.lowercased() ?? ""

        if Self.trackingDomains.contains(where: { domain in
            if domain.contains("/") {
                return normalized.contains(domain)
            }

            guard let host else { return false }
            return host == domain || host.hasSuffix(".\(domain)")
        }) {
            return true
        }

        if let host,
           Self.trackingSubdomains.contains(where: { token in
               host == token || host.hasPrefix("\(token).") || host.contains(".\(token).")
           }) {
            return true
        }

        let lastPathComponent = (path as NSString).lastPathComponent
        if Self.trackingFilenames.contains(lastPathComponent) {
            return true
        }

        return false
    }
}
