import Foundation

enum HTMLDisplayPurpose: String, CaseIterable, Sendable {
    case preview
    case original
}

/// Wraps HTML content for display in WebView with proper styling and security
/// Designed to match Apple Mail's rendering behavior as closely as possible
struct HTMLDisplayWrapper {
    struct Theme: Equatable, Sendable {
        let backgroundColorHex: String
        let textColorHex: String
    }

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

        // Check if HTML already has a complete document structure
        let hasDoctype = html.lowercased().contains("<!doctype")
        let hasHtmlTag = html.lowercased().contains("<html")

        // If the email already has a full HTML structure, inject our styles minimally
        if hasDoctype || hasHtmlTag {
            return wrapExistingDocument(
                sanitized,
                isDarkMode: isDarkMode,
                theme: theme,
                displayPurpose: displayPurpose
            )
        }

        // For partial HTML (no document structure), wrap with our template
        return wrapPartialHTML(
            sanitized,
            isDarkMode: isDarkMode,
            theme: theme,
            displayPurpose: displayPurpose
        )
    }

    /// Wraps HTML that already has document structure - inject styles without breaking existing layout
    private func wrapExistingDocument(
        _ html: String,
        isDarkMode: Bool,
        theme: Theme,
        displayPurpose: HTMLDisplayPurpose
    ) -> String {
        // Inject our viewport meta, CSP, and minimal styles into the existing document
        // This preserves the email's original <style> tags and media queries

        let shouldApplyDarkModeFallbackText = isDarkMode && displayPurpose == .preview

        let injectedHead = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
        <style id="esc-mail-styles">
            /* Minimal resets - don't override email's own styles */
            html {
                -webkit-text-size-adjust: 100%;
                background-color: \(theme.backgroundColorHex);
            }
            body {
                margin: 0;
                padding: 8px;
                background-color: \(theme.backgroundColorHex);
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

    /// Wraps partial HTML (no document structure) with our full template
    private func wrapPartialHTML(
        _ html: String,
        isDarkMode: Bool,
        theme: Theme,
        displayPurpose: HTMLDisplayPurpose
    ) -> String {
        let shouldApplyDarkModeFallbackText = isDarkMode && displayPurpose == .preview

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no, user-scalable=yes">
            <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
            <style>
                * {
                    box-sizing: border-box;
                }
                html {
                    -webkit-text-size-adjust: 100%;
                    background-color: \(theme.backgroundColorHex);
                }
                body {
                    color: \(theme.textColorHex);
                    background-color: \(theme.backgroundColorHex);
                    padding: 8px;
                    margin: 0;
                    word-wrap: break-word;
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

    /// Dark mode CSS overrides - only applied when email doesn't specify colors
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
