import Foundation

/// Analyzes HTML content to determine rendering complexity
struct HTMLComplexityAnalyzer {
    /// Analyzes HTML content and returns its complexity level
    func analyze(_ html: String) -> HTMLComplexity {
        let lowercased = html.lowercased()

        // Check for rich media elements that need WebView
        let hasTable = lowercased.contains("<table")
        let hasImage = lowercased.contains("<img")
        let hasVideo = lowercased.contains("<video")
        let hasAudio = lowercased.contains("<audio")
        let hasIframe = lowercased.contains("<iframe")
        let hasCanvas = lowercased.contains("<canvas")
        let hasSvg = lowercased.contains("<svg")

        if hasTable || hasImage || hasVideo || hasAudio || hasIframe || hasCanvas || hasSvg {
            return .complex
        }

        // Count total tags - newsletters typically have 100+ tags
        let tagPattern = "<[^>]+>"
        let regex = try? NSRegularExpression(pattern: tagPattern)
        let matches = regex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []

        // Only mark as moderate/complex if there are MANY tags
        if matches.count > 100 {
            return .complex
        } else if matches.count > 75 {
            return .moderate
        }

        // Everything else is simple (including basic Gmail replies with quoted text)
        return .simple
    }
}
