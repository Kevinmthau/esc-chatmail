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

    /// Removes tracking pixels from HTML content
    func removeTrackingPixels(_ html: String) -> String {
        var result = html

        // Remove 1x1 images by width/height attributes
        let range1 = NSRange(result.startIndex..., in: result)
        result = Self.pixelByAttributeRegex.stringByReplacingMatches(in: result, range: range1, withTemplate: "")

        // Remove 1x1 images by CSS style
        let range2 = NSRange(result.startIndex..., in: result)
        result = Self.pixelByCSSRegex.stringByReplacingMatches(in: result, range: range2, withTemplate: "")

        // Remove images from known tracking domains
        for domain in Self.trackingDomains {
            let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*\(escapedDomain)[^\"']*[\"'][^>]*>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Remove images from tracking subdomains (match at domain boundary)
        for subdomain in Self.trackingSubdomains {
            // Match subdomain at the start of domain or after a dot: //analytics. or .analytics.
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*(?://|\\.)\(subdomain)\\.[^\"']*[\"'][^>]*>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Remove images with common tracking filenames
        for filename in Self.trackingFilenames {
            let escapedFilename = NSRegularExpression.escapedPattern(for: filename)
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*/\(escapedFilename)[^\"']*[\"'][^>]*>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }
}
