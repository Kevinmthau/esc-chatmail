import Foundation

/// Wraps HTML content for display in WebView with proper styling and security
struct HTMLDisplayWrapper {
    /// Wraps HTML content with full HTML document structure and styling
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
            <!-- Relaxed CSP to allow all image sources -->
            <meta http-equiv="Content-Security-Policy" content="default-src * data: blob: 'unsafe-inline' 'unsafe-eval'; script-src 'none'; connect-src * data: blob:; img-src * data: blob: http: https:; frame-src 'none'; style-src * 'unsafe-inline';">
            <style>
                * {
                    box-sizing: border-box;
                }
                html, body {
                    height: 100%;
                    overflow: auto;
                    -webkit-overflow-scrolling: touch;
                }
                /* Default body styles - preserve email's own styling when possible */
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: \(textColor);
                    background-color: \(backgroundColor);
                    padding: 8px;
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
                /* Ensure images are responsive but respect their intended size */
                img {
                    max-width: 100% !important;
                    height: auto !important;
                    border: 0;
                    display: block;
                }
                /* Respect table layouts for newsletters */
                table {
                    max-width: 100% !important;
                    border-collapse: collapse;
                }
                /* Fix for nested tables in newsletters */
                table table {
                    width: 100% !important;
                }
                /* Preserve newsletter cell styling */
                td, th {
                    vertical-align: top;
                }
                /* Ensure text contrast in dark mode only when needed */
                \(isDarkMode ? """
                /* Only override text color if not already specified */
                p:not([style*="color"]),
                span:not([style*="color"]),
                div:not([style*="color"]),
                td:not([style*="color"]),
                th:not([style*="color"]),
                li:not([style*="color"]) {
                    color: \(textColor) !important;
                }
                """ : "")
            </style>
            <script>
                // Wait for DOM and images
                window.addEventListener('load', function() {
                    // Handle modern image formats that may not be supported
                    var images = document.getElementsByTagName('img');
                    for (var i = 0; i < images.length; i++) {
                        var img = images[i];

                        // Add comprehensive error handling
                        img.onerror = function() {
                            // Check if it's a modern format that needs fallback
                            var src = this.src || '';
                            if (src.includes('.webp') || src.includes('.avif') || src.includes('.jxl')) {
                                // Hide unsupported format images
                                this.style.display = 'none';
                                this.alt = this.alt || 'Image not available';
                            } else if (this.naturalWidth === 0) {
                                // Try one reload for other formats
                                if (!this.dataset.retried) {
                                    this.dataset.retried = 'true';
                                    var originalSrc = this.src;
                                    this.src = '';
                                    this.src = originalSrc;
                                } else {
                                    // Hide if still failing
                                    this.style.display = 'none';
                                }
                            }
                            this.onerror = null; // Prevent infinite loop
                        };

                        // Check if image failed to load initially
                        if (img.complete && img.naturalWidth === 0) {
                            img.onerror();
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

    /// Lighter sanitization that preserves more formatting
    func lightSanitize(_ html: String) -> String {
        var sanitized = html

        // Remove only the most dangerous elements
        sanitized = RegexSanitizer.replace(
            in: sanitized,
            pattern: "<script\\b[^<]*(?:(?!<\\/script>)<[^<]*)*<\\/script>|<script\\b[^>]*\\/>"
        )
        sanitized = RegexSanitizer.replace(
            in: sanitized,
            pattern: "\\s*on\\w+\\s*=\\s*[\"'][^\"']*[\"']|\\s*on\\w+\\s*=\\s*[^\\s>]+"
        )
        sanitized = RegexSanitizer.replace(
            in: sanitized,
            pattern: "<meta\\s+[^>]*http-equiv\\s*=\\s*[\"']refresh[\"'][^>]*>"
        )
        sanitized = RegexSanitizer.replace(
            in: sanitized,
            pattern: "<form\\b[^<]*(?:(?!<\\/form>)<[^<]*)*<\\/form>|<form\\b[^>]*\\/>"
        )
        sanitized = RegexSanitizer.replace(
            in: sanitized,
            pattern: "<iframe\\b[^<]*(?:(?!<\\/iframe>)<[^<]*)*<\\/iframe>|<iframe\\b[^>]*\\/>"
        )

        // Keep style tags for email formatting
        // Keep most HTML structure intact

        return sanitized
    }
}
