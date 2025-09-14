import Foundation
import WebKit
import UIKit

protocol HTMLSanitizerProtocol {
    func sanitize(_ html: String) -> String
    func htmlToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString?
    func analyzeComplexity(_ html: String) -> HTMLSanitizerService.HTMLComplexity
}

class HTMLSanitizerService: HTMLSanitizerProtocol {
    static let shared = HTMLSanitizerService()

    private init() {}

    // MARK: - Allowed HTML Elements & Attributes

    private let allowedTags: Set<String> = [
        // Text formatting
        "p", "br", "span", "div", "blockquote",
        "b", "strong", "i", "em", "u", "s", "strike",
        "h1", "h2", "h3", "h4", "h5", "h6",

        // Lists
        "ul", "ol", "li", "dl", "dt", "dd",

        // Links (with sanitized href)
        "a",

        // Tables
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",

        // Media (with sanitized src)
        "img",

        // Code
        "code", "pre", "kbd", "var", "samp",

        // Semantic
        "article", "section", "nav", "aside", "header", "footer", "main",

        // Other
        "hr", "abbr", "time", "mark", "small", "sub", "sup"
    ]

    private let allowedAttributes: [String: Set<String>] = [
        "a": ["href", "title", "target", "rel"],
        "img": ["src", "alt", "title", "width", "height"],
        "blockquote": ["cite"],
        "time": ["datetime"],
        "abbr": ["title"],
        "td": ["colspan", "rowspan"],
        "th": ["colspan", "rowspan", "scope"],
        "*": ["class", "id", "style"] // Carefully sanitized
    ]

    private let allowedProtocols: Set<String> = [
        "http", "https", "mailto", "tel"
    ]

    // MARK: - Main Sanitization Method

    func sanitize(_ html: String) -> String {
        var sanitized = html

        // Remove dangerous elements
        sanitized = removeDangerousElements(sanitized)

        // Remove script tags and content
        sanitized = removeScriptTags(sanitized)

        // Remove style tags but preserve inline styles (sanitized)
        sanitized = removeStyleTags(sanitized)

        // Remove event handlers
        sanitized = removeEventHandlers(sanitized)

        // Sanitize URLs
        sanitized = sanitizeURLs(sanitized)

        // Remove meta refresh
        sanitized = removeMetaRefresh(sanitized)

        // Remove forms
        sanitized = removeForms(sanitized)

        // Remove iframes
        sanitized = removeIframes(sanitized)

        // Clean up Gmail-specific elements
        sanitized = removeGmailElements(sanitized)

        // Remove tracking pixels
        sanitized = removeTrackingPixels(sanitized)

        // Sanitize CSS in style attributes
        sanitized = sanitizeInlineStyles(sanitized)

        return sanitized
    }

    // MARK: - Specific Sanitization Methods

    private func removeDangerousElements(_ html: String) -> String {
        let dangerousTags = [
            "script", "noscript", "object", "embed", "applet",
            "frame", "frameset", "iframe", "base", "basefont",
            "form", "input", "button", "select", "textarea",
            "option", "optgroup", "fieldset", "legend", "label",
            "meta", "link"
        ]

        var result = html
        for tag in dangerousTags {
            // Remove opening and closing tags and their content
            let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>|<\(tag)\\b[^>]*/?>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private func removeScriptTags(_ html: String) -> String {
        let scriptPattern = "<script\\b[^<]*(?:(?!<\\/script>)<[^<]*)*<\\/script>|<script\\b[^>]*\\/>"
        return html.replacingOccurrences(
            of: scriptPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func removeStyleTags(_ html: String) -> String {
        let stylePattern = "<style\\b[^<]*(?:(?!<\\/style>)<[^<]*)*<\\/style>"
        return html.replacingOccurrences(
            of: stylePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func removeEventHandlers(_ html: String) -> String {
        let eventPattern = "\\s*on\\w+\\s*=\\s*[\"'][^\"']*[\"']|\\s*on\\w+\\s*=\\s*[^\\s>]+"
        return html.replacingOccurrences(
            of: eventPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func sanitizeURLs(_ html: String) -> String {
        var result = html

        // Sanitize href attributes
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

        // Sanitize src attributes
        let srcPattern = "src\\s*=\\s*[\"']([^\"']*)[\"']"
        let srcRegex = try? NSRegularExpression(pattern: srcPattern, options: .caseInsensitive)
        let srcMatches = srcRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []

        for match in srcMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let url = String(result[range])
                if !isURLSafe(url) && !isDataURL(url) {
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: "src=\"\"")
                }
            }
        }

        return result
    }

    private func isURLSafe(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Block javascript: and data: URLs (except safe data: images)
        if trimmed.hasPrefix("javascript:") || trimmed.hasPrefix("vbscript:") {
            return false
        }

        // Allow data URLs for images only
        if trimmed.hasPrefix("data:") {
            return isDataURL(trimmed)
        }

        // Check if URL starts with allowed protocol
        for proto in allowedProtocols {
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

    private func isDataURL(_ url: String) -> Bool {
        let safeDataURLPattern = "^data:image\\/(png|jpeg|jpg|gif|webp|svg\\+xml);base64,"
        return url.range(of: safeDataURLPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func removeMetaRefresh(_ html: String) -> String {
        let metaPattern = "<meta\\s+[^>]*http-equiv\\s*=\\s*[\"']refresh[\"'][^>]*>"
        return html.replacingOccurrences(
            of: metaPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func removeForms(_ html: String) -> String {
        let formPattern = "<form\\b[^<]*(?:(?!<\\/form>)<[^<]*)*<\\/form>|<form\\b[^>]*\\/>"
        return html.replacingOccurrences(
            of: formPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func removeIframes(_ html: String) -> String {
        let iframePattern = "<iframe\\b[^<]*(?:(?!<\\/iframe>)<[^<]*)*<\\/iframe>|<iframe\\b[^>]*\\/>"
        return html.replacingOccurrences(
            of: iframePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func removeGmailElements(_ html: String) -> String {
        let result = html

        // Don't remove Gmail signatures and quotes - keep them for full display
        // Users want to see the complete email when viewing rich content

        return result
    }

    private func removeTrackingPixels(_ html: String) -> String {
        // Remove 1x1 images (tracking pixels) - but be careful not to remove legitimate small images
        let trackingPattern = "<img[^>]*(?:width\\s*=\\s*[\"']1[\"']\\s+height\\s*=\\s*[\"']1[\"']|height\\s*=\\s*[\"']1[\"']\\s+width\\s*=\\s*[\"']1[\"'])[^>]*>"
        var result = html.replacingOccurrences(
            of: trackingPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove images from known tracking domains
        let trackingDomains = [
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

        for domain in trackingDomains {
            let pattern = "<img[^>]*src\\s*=\\s*[\"'][^\"']*\(domain)[^\"']*[\"'][^>]*>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }

    private func sanitizeInlineStyles(_ html: String) -> String {
        let stylePattern = "style\\s*=\\s*[\"']([^\"']*)[\"']"
        let regex = try? NSRegularExpression(pattern: stylePattern, options: .caseInsensitive)
        let matches = regex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []

        var result = html
        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let styleContent = String(result[range])
                let sanitizedStyle = sanitizeCSS(styleContent)
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "style=\"\(sanitizedStyle)\"")
            }
        }

        return result
    }

    private func sanitizeCSS(_ css: String) -> String {
        var sanitized = css

        // Remove javascript: in CSS
        sanitized = sanitized.replacingOccurrences(
            of: "javascript:",
            with: "",
            options: .caseInsensitive
        )

        // Remove expression() in CSS (IE specific)
        sanitized = sanitized.replacingOccurrences(
            of: "expression\\s*\\([^)]*\\)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove @import
        sanitized = sanitized.replacingOccurrences(
            of: "@import[^;]*;",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove behavior property (IE specific)
        sanitized = sanitized.replacingOccurrences(
            of: "behavior\\s*:[^;]*;",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove -moz-binding (Firefox specific)
        sanitized = sanitized.replacingOccurrences(
            of: "-moz-binding\\s*:[^;]*;",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return sanitized
    }

    // MARK: - HTML to AttributedString Conversion

    func htmlToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString? {
        // First sanitize the HTML
        let sanitized = sanitize(html)

        // Check if HTML is simple enough for AttributedString
        if isSimpleHTML(sanitized) {
            return convertToAttributedString(sanitized, isFromMe: isFromMe)
        }

        return nil
    }

    private func isSimpleHTML(_ html: String) -> Bool {
        // Check if HTML only contains simple formatting tags
        let complexPatterns = [
            "<table", "<img", "<video", "<audio", "<iframe",
            "<form", "<input", "<canvas", "<svg"
        ]

        let lowercased = html.lowercased()
        for pattern in complexPatterns {
            if lowercased.contains(pattern) {
                return false
            }
        }

        return true
    }

    private func convertToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        do {
            let attributed = try NSMutableAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            )

            // Apply theme colors
            let textColor = isFromMe ? UIColor.white : UIColor.label
            let linkColor = isFromMe ? UIColor(red: 0.68, green: 0.85, blue: 0.9, alpha: 1.0) : UIColor.systemBlue

            attributed.addAttributes([
                .foregroundColor: textColor,
                .font: UIFont.systemFont(ofSize: 16)
            ], range: NSRange(location: 0, length: attributed.length))

            // Update link colors
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                if value != nil {
                    attributed.addAttribute(.foregroundColor, value: linkColor, range: range)
                }
            }

            return attributed
        } catch {
            return nil
        }
    }

    // MARK: - HTML Complexity Analyzer

    enum HTMLComplexity {
        case simple    // Can use AttributedString
        case moderate  // Need WebView but with optimizations
        case complex   // Full WebView rendering
    }

    func analyzeComplexity(_ html: String) -> HTMLComplexity {
        let lowercased = html.lowercased()

        // Check for complex elements
        if lowercased.contains("<table") ||
           lowercased.contains("<img") ||
           lowercased.contains("<video") ||
           lowercased.contains("<iframe") {
            return .complex
        }

        // Check for moderate complexity
        if lowercased.contains("<div") && lowercased.contains("style") {
            return .moderate
        }

        // Count total tags
        let tagPattern = "<[^>]+>"
        let regex = try? NSRegularExpression(pattern: tagPattern)
        let matches = regex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []

        if matches.count > 50 {
            return .complex
        } else if matches.count > 20 {
            return .moderate
        }

        return .simple
    }

    // MARK: - HTML Wrapping for Display

    func wrapHTMLForDisplay(_ html: String, isDarkMode: Bool) -> String {
        // Use lighter sanitization to preserve email formatting
        let sanitized = lightSanitize(html)

        let backgroundColor = isDarkMode ? "#1c1c1e" : "#ffffff"
        let textColor = isDarkMode ? "#ffffff" : "#000000"
        let linkColor = isDarkMode ? "#4da6ff" : "#007aff"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
            <meta http-equiv="Content-Security-Policy" content="default-src * data: blob: 'unsafe-inline' 'unsafe-eval'; script-src * data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src * data: blob: 'unsafe-inline'; img-src * data: blob: 'unsafe-inline'; frame-src * data: blob: ; style-src * data: blob: 'unsafe-inline';">
            <style>
                * {
                    box-sizing: border-box;
                }
                html, body {
                    height: 100%;
                    overflow: auto;
                    -webkit-overflow-scrolling: touch;
                }
                /* Default body styles - can be overridden by email styles */
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: \(textColor);
                    background-color: \(backgroundColor);
                    padding: 16px;
                    margin: 0;
                    word-wrap: break-word;
                    -webkit-text-size-adjust: 100%;
                }
                /* Override link colors */
                a {
                    color: \(linkColor) !important;
                    text-decoration: none;
                }
                a:hover {
                    text-decoration: underline;
                }
                /* Ensure images are responsive */
                img {
                    max-width: 100% !important;
                    height: auto !important;
                    border: 0;
                }
                /* Table improvements */
                table {
                    max-width: 100% !important;
                    width: auto !important;
                }
                /* Fix for nested tables */
                table table {
                    width: 100% !important;
                }
                /* Ensure text contrast in dark mode */
                \(isDarkMode ? """
                p, span, div, td, th, li {
                    color: \(textColor) !important;
                }
                """ : "")
            </style>
            <script>
                // Wait for DOM and images
                window.addEventListener('load', function() {
                    // Force image reload if needed
                    var images = document.getElementsByTagName('img');
                    for (var i = 0; i < images.length; i++) {
                        var img = images[i];
                        if (img.naturalWidth === 0) {
                            var src = img.src;
                            img.src = '';
                            img.src = src;
                        }
                    }

                    // Adjust viewport for better display
                    var content = document.body;
                    if (content.scrollWidth > window.innerWidth) {
                        var scale = window.innerWidth / content.scrollWidth;
                        document.body.style.zoom = scale;
                    }
                });
            </script>
        </head>
        <body>
            \(sanitized)
        </body>
        </html>
        """
    }

    // Lighter sanitization that preserves more formatting
    private func lightSanitize(_ html: String) -> String {
        var sanitized = html

        // Remove only the most dangerous elements
        sanitized = removeScriptTags(sanitized)
        sanitized = removeEventHandlers(sanitized)
        sanitized = removeMetaRefresh(sanitized)
        sanitized = removeForms(sanitized)
        sanitized = removeIframes(sanitized)

        // Keep style tags for email formatting
        // Keep most HTML structure intact

        return sanitized
    }
}