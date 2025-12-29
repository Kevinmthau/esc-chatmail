import Foundation
import WebKit
import UIKit

/// Main HTML sanitization service - facade delegating to specialized components
final class HTMLSanitizerService: HTMLSanitizerProtocol {
    static let shared = HTMLSanitizerService()

    // MARK: - Internal Components

    private let urlSanitizer = HTMLURLSanitizer()
    private let cssSanitizer = HTMLCSSSanitizer()
    private let trackingRemover = HTMLTrackingRemover()
    private let attributedConverter = HTMLAttributedStringConverter()
    private let complexityAnalyzer = HTMLComplexityAnalyzer()
    private let displayWrapper = HTMLDisplayWrapper()

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

    // MARK: - Dangerous Tags Configuration

    private static let dangerousTags = [
        "script", "noscript", "object", "embed", "applet",
        "frame", "frameset", "iframe", "base", "basefont",
        "form", "input", "button", "select", "textarea",
        "option", "optgroup", "fieldset", "legend", "label",
        "meta", "link"
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

        // Sanitize URLs (delegated)
        sanitized = urlSanitizer.sanitizeURLs(sanitized)

        // Remove meta refresh
        sanitized = removeMetaRefresh(sanitized)

        // Remove forms
        sanitized = removeForms(sanitized)

        // Remove iframes
        sanitized = removeIframes(sanitized)

        // Clean up Gmail-specific elements
        sanitized = removeGmailElements(sanitized)

        // Remove tracking pixels (delegated)
        sanitized = trackingRemover.removeTrackingPixels(sanitized)

        // Sanitize CSS in style attributes (delegated)
        sanitized = cssSanitizer.sanitizeInlineStyles(sanitized)

        return sanitized
    }

    // MARK: - Specific Sanitization Methods

    private func removeDangerousElements(_ html: String) -> String {
        RegexSanitizer.removeTags(from: html, tags: Self.dangerousTags)
    }

    private func removeScriptTags(_ html: String) -> String {
        RegexSanitizer.replace(
            in: html,
            pattern: "<script\\b[^<]*(?:(?!<\\/script>)<[^<]*)*<\\/script>|<script\\b[^>]*\\/>"
        )
    }

    private func removeStyleTags(_ html: String) -> String {
        RegexSanitizer.replace(
            in: html,
            pattern: "<style\\b[^<]*(?:(?!<\\/style>)<[^<]*)*<\\/style>"
        )
    }

    private func removeEventHandlers(_ html: String) -> String {
        RegexSanitizer.replace(
            in: html,
            pattern: "\\s*on\\w+\\s*=\\s*[\"'][^\"']*[\"']|\\s*on\\w+\\s*=\\s*[^\\s>]+"
        )
    }

    private func removeMetaRefresh(_ html: String) -> String {
        RegexSanitizer.replace(
            in: html,
            pattern: "<meta\\s+[^>]*http-equiv\\s*=\\s*[\"']refresh[\"'][^>]*>"
        )
    }

    private func removeForms(_ html: String) -> String {
        RegexSanitizer.replace(
            in: html,
            pattern: "<form\\b[^<]*(?:(?!<\\/form>)<[^<]*)*<\\/form>|<form\\b[^>]*\\/>"
        )
    }

    private func removeIframes(_ html: String) -> String {
        RegexSanitizer.replace(
            in: html,
            pattern: "<iframe\\b[^<]*(?:(?!<\\/iframe>)<[^<]*)*<\\/iframe>|<iframe\\b[^>]*\\/>"
        )
    }

    private func removeGmailElements(_ html: String) -> String {
        // Don't remove Gmail signatures and quotes - keep them for full display
        // Users want to see the complete email when viewing rich content
        return html
    }

    // MARK: - HTML to AttributedString Conversion

    func htmlToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString? {
        let sanitized = sanitize(html)
        return attributedConverter.convert(sanitized, isFromMe: isFromMe)
    }

    // MARK: - HTML Complexity Analysis

    func analyzeComplexity(_ html: String) -> HTMLComplexity {
        complexityAnalyzer.analyze(html)
    }

    // MARK: - HTML Wrapping for Display

    func wrapHTMLForDisplay(_ html: String, isDarkMode: Bool) -> String {
        displayWrapper.wrapHTMLForDisplay(html, isDarkMode: isDarkMode)
    }
}
