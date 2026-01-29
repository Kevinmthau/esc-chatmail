import Foundation

/// Wraps HTML content for display in WebView with proper styling and security
/// Designed to match Apple Mail's rendering behavior as closely as possible
struct HTMLDisplayWrapper {
    /// Wraps HTML content with full HTML document structure and styling
    /// Note: HTML should already be sanitized by HTMLSanitizerService.sanitize() before calling this
    func wrapHTMLForDisplay(_ html: String, isDarkMode: Bool) -> String {
        // Content is pre-sanitized by HTMLSanitizerService, so we just wrap it
        let sanitized = html

        let backgroundColor = isDarkMode ? "#1c1c1e" : "#ffffff"
        let textColor = isDarkMode ? "#ffffff" : "#000000"

        // Check if HTML already has a complete document structure
        let hasDoctype = html.lowercased().contains("<!doctype")
        let hasHtmlTag = html.lowercased().contains("<html")

        // If the email already has a full HTML structure, inject our styles minimally
        if hasDoctype || hasHtmlTag {
            return wrapExistingDocument(sanitized, isDarkMode: isDarkMode, backgroundColor: backgroundColor, textColor: textColor)
        }

        // For partial HTML (no document structure), wrap with our template
        return wrapPartialHTML(sanitized, isDarkMode: isDarkMode, backgroundColor: backgroundColor, textColor: textColor)
    }

    /// Wraps HTML that already has document structure - inject styles without breaking existing layout
    private func wrapExistingDocument(_ html: String, isDarkMode: Bool, backgroundColor: String, textColor: String) -> String {
        // Inject our viewport meta, CSP, and minimal styles into the existing document
        // This preserves the email's original <style> tags and media queries

        let injectedHead = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
        <style id="esc-mail-styles">
            /* Minimal resets - don't override email's own styles */
            html {
                -webkit-text-size-adjust: 100%;
            }
            body {
                margin: 0;
                padding: 8px;
                background-color: \(backgroundColor);
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
            /* Reset link styling to inherit - allows email's inline styles to work */
            a {
                color: inherit;
                text-decoration: inherit;
            }
            \(isDarkMode ? darkModeCSS(textColor: textColor) : "")
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
    private func wrapPartialHTML(_ html: String, isDarkMode: Bool, backgroundColor: String, textColor: String) -> String {
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
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: \(textColor);
                    background-color: \(backgroundColor);
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
                /* Reset link styling to inherit - allows email's inline styles to work */
                a {
                    color: inherit;
                    text-decoration: inherit;
                }
                /* Text wrapping */
                div, td, th, p {
                    overflow-wrap: break-word;
                    word-break: break-word;
                }
                td, th {
                    vertical-align: top;
                }
                \(isDarkMode ? darkModeCSS(textColor: textColor) : "")
            </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
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
