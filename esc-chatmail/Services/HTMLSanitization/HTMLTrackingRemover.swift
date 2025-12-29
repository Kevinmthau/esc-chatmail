import Foundation

/// Removes tracking pixels and known tracking elements from HTML
struct HTMLTrackingRemover {
    private static let trackingDomains = [
        "googleadservices.com",
        "doubleclick.net",
        "google-analytics.com",
        "googlesyndication.com",
        "facebook.com/tr",
        "analytics.",
        "tracking.",
        "pixel.",
        "beacon."
    ]

    /// Removes tracking pixels from HTML content
    func removeTrackingPixels(_ html: String) -> String {
        // Remove 1x1 images (tracking pixels)
        let trackingPattern = "<img[^>]*(?:width\\s*=\\s*[\"']1[\"']\\s+height\\s*=\\s*[\"']1[\"']|height\\s*=\\s*[\"']1[\"']\\s+width\\s*=\\s*[\"']1[\"'])[^>]*>"
        var result = html.replacingOccurrences(
            of: trackingPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove images from known tracking domains
        for domain in Self.trackingDomains {
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*\(domain)[^\"']*[\"'][^>]*>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }
}
