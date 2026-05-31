import Foundation
import SwiftSoup

enum HTMLDisplayPurpose: String, CaseIterable, Sendable {
    case preview
    case original
}

/// Wraps HTML content for display in WebView with proper styling and security
/// Designed to match Apple Mail's rendering behavior as closely as possible
struct HTMLDisplayWrapper {
    private static let appleMailFallbackFontStack = "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    static let minimumFixedLayoutViewportWidth = 376
    static let maximumResponsiveLayoutViewportWidth = 480
    static let maximumFixedLayoutViewportWidth = 900

    /// Fallback colors for the wrapper-owned surface.
    ///
    /// These colors should not be treated as an instruction to rewrite authored
    /// email colors. They are the background/text defaults used when the email
    /// leaves parts of the document unstyled.
    struct Theme: Equatable, Sendable {
        let backgroundColorHex: String
        let textColorHex: String
    }

    /// Returns the wrapper fallback theme for a display purpose.
    ///
    /// Preview rendering follows the app appearance so chat cards remain readable
    /// in dark mode. Original-email rendering deliberately returns the light theme
    /// for both system appearances to preserve authored colors and layout intent.
    static func theme(
        isDarkMode: Bool,
        displayPurpose: HTMLDisplayPurpose
    ) -> Theme {
        switch (displayPurpose, isDarkMode) {
        case (.preview, false):
            return Theme(backgroundColorHex: "#f2f2f7", textColorHex: "#000000")
        case (.preview, true):
            return Theme(backgroundColorHex: "#1c1c1e", textColorHex: "#ffffff")
        case (.original, false):
            return Theme(backgroundColorHex: "#ffffff", textColorHex: "#000000")
        case (.original, true):
            // Full-message rendering should preserve authored colors instead of forcing
            // the document onto a dark surface that many emails were never designed for.
            return Theme(backgroundColorHex: "#ffffff", textColorHex: "#000000")
        }
    }

    /// Wraps HTML content with full HTML document structure and styling
    /// Note: HTML should already be sanitized by HTMLSanitizerService.sanitize() before calling this
    func wrapHTMLForDisplay(
        _ html: String,
        isDarkMode: Bool,
        displayPurpose: HTMLDisplayPurpose = .preview
    ) -> String {
        // Content is pre-sanitized by HTMLSanitizerService, so we just wrap it
        let sanitized = html
        let theme = Self.theme(isDarkMode: isDarkMode, displayPurpose: displayPurpose)
        let fallbackTypographyCSS = originalFallbackTypographyCSSIfNeeded(
            for: sanitized,
            displayPurpose: displayPurpose
        )

        // Check if HTML already has a complete document structure
        let hasDoctype = html.lowercased().contains("<!doctype")
        let hasHtmlTag = html.lowercased().contains("<html")

        // If the email already has a full HTML structure, inject our styles minimally
        if hasDoctype || hasHtmlTag {
            return wrapExistingDocument(
                sanitized,
                isDarkMode: isDarkMode,
                theme: theme,
                displayPurpose: displayPurpose,
                fallbackTypographyCSS: fallbackTypographyCSS
            )
        }

        // For partial HTML (no document structure), wrap with our template
        return wrapPartialHTML(
            sanitized,
            isDarkMode: isDarkMode,
            theme: theme,
            displayPurpose: displayPurpose,
            fallbackTypographyCSS: fallbackTypographyCSS
        )
    }

    /// Wraps HTML that already has document structure - inject styles without breaking existing layout
    private func wrapExistingDocument(
        _ html: String,
        isDarkMode: Bool,
        theme: Theme,
        displayPurpose: HTMLDisplayPurpose,
        fallbackTypographyCSS: String
    ) -> String {
        // Inject our viewport meta, CSP, and minimal styles into the existing document
        // This preserves the email's original <style> tags and media queries

        // Preview is the only display purpose that gets dark-mode fallback text.
        // Full original emails stay light-authored, including when the app is dark.
        let shouldApplyDarkModeFallbackText = isDarkMode && displayPurpose == .preview
        let originalColorSchemeHead = colorSchemeHead(for: displayPurpose)
        let originalColorSchemeCSS = colorSchemeCSS(for: displayPurpose)
        let viewportMetaTag = viewportMetaTag(for: displayPurpose, html: html)

        let injectedHead = """
        \(viewportMetaTag)
        \(originalColorSchemeHead)
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
        <style id="esc-mail-styles">
            /* Minimal resets - don't override email's own styles */
            html {
                -webkit-text-size-adjust: 100%;
                background-color: \(theme.backgroundColorHex);
                \(originalColorSchemeCSS)
            }
            body {
                margin: 0;
                padding: 8px;
                background-color: \(theme.backgroundColorHex);
                \(fallbackTypographyCSS)
            }
            /* Only constrain images that would overflow */
            img {
                max-width: 100%;
                height: auto;
            }
            /* Allow tables to shrink but don't force width */
            table {
                max-width: 100%;
            }
            \(linkCSS(for: displayPurpose))
            \(shouldApplyDarkModeFallbackText ? darkModeCSS(textColor: theme.textColorHex) : "")
        </style>
        """

        if let wrapped = wrapExistingDocumentWithDOM(
            html,
            injectedHead: injectedHead
        ) {
            return wrapped
        }

        var result = html

        // Try to inject after existing <head> tag
        if let headRange = result.range(of: "<head>", options: .caseInsensitive) {
            result.insert(contentsOf: "\n" + injectedHead + "\n", at: headRange.upperBound)
        } else if let headRange = result.range(of: "<head ", options: .caseInsensitive) {
            // Handle <head ...> with attributes
            if let closingBracket = result[headRange.upperBound...].range(of: ">") {
                result.insert(contentsOf: "\n" + injectedHead + "\n", at: closingBracket.upperBound)
            }
        } else if let htmlRange = result.range(of: "<html>", options: .caseInsensitive) {
            // No head tag, inject after <html>
            result.insert(contentsOf: "\n<head>\n" + injectedHead + "\n</head>\n", at: htmlRange.upperBound)
        } else if let htmlRange = result.range(of: "<html ", options: .caseInsensitive) {
            if let closingBracket = result[htmlRange.upperBound...].range(of: ">") {
                result.insert(contentsOf: "\n<head>\n" + injectedHead + "\n</head>\n", at: closingBracket.upperBound)
            }
        }

        // Ensure we have a proper doctype
        if !result.lowercased().contains("<!doctype") {
            result = "<!DOCTYPE html>\n" + result
        }

        return result
    }

    private func wrapExistingDocumentWithDOM(
        _ html: String,
        injectedHead: String
    ) -> String? {
        do {
            let document = try SwiftSoup.parse(html)
            document.outputSettings().prettyPrint(pretty: false)

            let head = try existingOrInsertedHead(in: document)
            try head.prepend("\n" + injectedHead + "\n")

            var result = normalizeSerializedHeadHTML(try document.outerHtml())
            result = preserveOriginalDoctypeCasing(in: result, originalHTML: html)
            if !result.lowercased().contains("<!doctype") {
                result = "<!DOCTYPE html>\n" + result
            }
            return result
        } catch {
            return nil
        }
    }

    private func existingOrInsertedHead(in document: Document) throws -> Element {
        if let head = document.head() {
            return head
        }

        if let htmlElement = try document.select("html").first() {
            return try htmlElement.prependElement("head")
        }

        return try document.prependElement("head")
    }

    private func normalizeSerializedHeadHTML(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<meta\b([^>]*)\s/>"#,
            with: #"<meta$1>"#,
            options: .regularExpression
        )
    }

    private func preserveOriginalDoctypeCasing(in wrappedHTML: String, originalHTML: String) -> String {
        guard let originalRange = originalHTML.range(of: "<!doctype", options: .caseInsensitive),
              let wrappedRange = wrappedHTML.range(of: "<!doctype", options: .caseInsensitive) else {
            return wrappedHTML
        }

        var restored = wrappedHTML
        restored.replaceSubrange(wrappedRange, with: originalHTML[originalRange])
        return restored
    }

    /// Wraps partial HTML (no document structure) with our full template
    private func wrapPartialHTML(
        _ html: String,
        isDarkMode: Bool,
        theme: Theme,
        displayPurpose: HTMLDisplayPurpose,
        fallbackTypographyCSS: String
    ) -> String {
        // Preview is the only display purpose that gets dark-mode fallback text.
        // Full original emails stay light-authored, including when the app is dark.
        let shouldApplyDarkModeFallbackText = isDarkMode && displayPurpose == .preview
        let originalColorSchemeHead = colorSchemeHead(for: displayPurpose)
        let originalColorSchemeCSS = colorSchemeCSS(for: displayPurpose)
        let viewportMetaTag = viewportMetaTag(for: displayPurpose, html: html)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            \(viewportMetaTag)
            \(originalColorSchemeHead)
            <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
            <style>
                * {
                    box-sizing: border-box;
                }
                html {
                    -webkit-text-size-adjust: 100%;
                    background-color: \(theme.backgroundColorHex);
                    \(originalColorSchemeCSS)
                }
                body {
                    color: \(theme.textColorHex);
                    background-color: \(theme.backgroundColorHex);
                    padding: 8px;
                    margin: 0;
                    word-wrap: break-word;
                    \(fallbackTypographyCSS)
                }
                /* Constrain images without breaking layout */
                img {
                    max-width: 100%;
                    height: auto;
                    border: 0;
                }
                /* Allow tables to shrink but preserve intentional widths */
                table {
                    max-width: 100%;
                    border-collapse: collapse;
                }
                \(linkCSS(for: displayPurpose))
                /* Text wrapping */
                div, td, th, p {
                    overflow-wrap: break-word;
                    word-break: break-word;
                }
                td, th {
                    vertical-align: top;
                }
                \(shouldApplyDarkModeFallbackText ? darkModeCSS(textColor: theme.textColorHex) : "")
            </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """
    }

    private func originalFallbackTypographyCSSIfNeeded(
        for html: String,
        displayPurpose: HTMLDisplayPurpose
    ) -> String {
        guard shouldApplyOriginalFallbackTypography(to: html, displayPurpose: displayPurpose) else {
            return ""
        }

        // Fragment-style emails often omit any font declaration and rely on the mail client's
        // default body typography. Match Apple Mail more closely here instead of falling back
        // to WKWebView's default serif font.
        return """
        font-family: \(Self.appleMailFallbackFontStack);
        """
    }

    private func shouldApplyOriginalFallbackTypography(
        to html: String,
        displayPurpose: HTMLDisplayPurpose
    ) -> Bool {
        guard displayPurpose == .original else {
            return false
        }

        return !documentDefinesOriginalTypography(in: html)
    }

    private func documentDefinesOriginalTypography(in html: String) -> Bool {
        RootTypographyDetector.containsAuthoredTypography(in: html)
    }

    private func colorSchemeHead(for displayPurpose: HTMLDisplayPurpose) -> String {
        guard displayPurpose == .original else {
            return ""
        }

        return """
        <meta name="color-scheme" content="light">
        <meta name="supported-color-schemes" content="light">
        """
    }

    private func colorSchemeCSS(for displayPurpose: HTMLDisplayPurpose) -> String {
        guard displayPurpose == .original else {
            return ""
        }

        return "color-scheme: light;"
    }

    private func viewportMetaTag(for displayPurpose: HTMLDisplayPurpose, html: String) -> String {
        switch displayPurpose {
        case .preview:
            return #"<meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no, user-scalable=yes">"#
        case .original:
            // Some marketing emails still rely on WebKit's initial shrink-to-fit behavior for
            // legacy fixed-width sections that intentionally do not stack on mobile.
            if let fixedWidth = EmailLayoutDetector.originalFixedLayoutViewportWidth(in: html) {
                return #"<meta name="viewport" content="width=\#(fixedWidth), user-scalable=yes">"#
            }
            return #"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#
        }
    }

    private func linkCSS(for displayPurpose: HTMLDisplayPurpose) -> String {
        guard displayPurpose == .preview else {
            return ""
        }

        return """
        /* Preview cards should inherit surrounding text styling. */
        a {
            color: inherit;
            text-decoration: inherit;
        }
        """
    }

    /// Preview-only dark-mode fallback text.
    ///
    /// This intentionally targets common unstyled elements and avoids elements
    /// with inline colors so authored color choices survive where possible.
    private func darkModeCSS(textColor: String) -> String {
        return """
        /* Dark mode: only override text color if not already specified */
        p:not([style*="color"]),
        span:not([style*="color"]),
        div:not([style*="color"]),
        td:not([style*="color"]),
        th:not([style*="color"]),
        li:not([style*="color"]) {
            color: \(textColor);
        }
        """
    }
}
