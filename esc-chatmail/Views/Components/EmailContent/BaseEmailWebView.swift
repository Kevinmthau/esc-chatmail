import SwiftUI
import WebKit

/// Configuration mode for email WebView rendering
enum EmailWebViewMode {
    /// Full interactive view with JavaScript, scrolling, and link handling
    case fullInteractive
    /// Scaled preview (e.g., 50%) with no interaction
    case scaledPreview(scale: CGFloat)
    /// Simple non-interactive preview at full size
    case simplePreview
}

/// Unified WebView for rendering email HTML content
/// Consolidates HTMLWebView, MiniEmailWebView, and HTMLPreviewWebView
struct BaseEmailWebView: UIViewRepresentable {
    let htmlContent: String
    let mode: EmailWebViewMode
    var isDarkMode: Bool = false
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Register cid: scheme handler for inline attachments
        let cidHandler = CIDSchemeHandler(message: message)
        context.coordinator.cidHandler = cidHandler
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")

        switch mode {
        case .fullInteractive:
            configuration.allowsInlineMediaPlayback = true
            configuration.dataDetectorTypes = [.phoneNumber, .link, .address]
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.allowsAirPlayForMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        case .scaledPreview, .simplePreview:
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        switch mode {
        case .fullInteractive:
            // Match Apple Mail's WebView behavior
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = true
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            // Use mobile user agent to trigger responsive media queries
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
            // Prevent automatic font size adjustment that can break layouts
            webView.configuration.preferences.minimumFontSize = 0
        case .scaledPreview:
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.isUserInteractionEnabled = false
            webView.isOpaque = false
            webView.backgroundColor = .secondarySystemBackground
            webView.scrollView.backgroundColor = .secondarySystemBackground
        case .simplePreview:
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.isUserInteractionEnabled = false
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }

        context.coordinator.loadContent(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.needsReload {
            context.coordinator.loadContent(in: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BaseEmailWebView
        var lastLoadedContent: String = ""
        var lastLoadedModeSignature: String = ""
        private var isLoading = false
        /// Holds strong reference to the cid: scheme handler
        var cidHandler: CIDSchemeHandler?

        init(_ parent: BaseEmailWebView) {
            self.parent = parent
        }

        var needsReload: Bool {
            lastLoadedContent != parent.htmlContent || lastLoadedModeSignature != modeSignature(for: parent.mode)
        }

        func loadContent(in webView: WKWebView) {
            guard !isLoading else { return }
            isLoading = true
            lastLoadedContent = parent.htmlContent
            lastLoadedModeSignature = modeSignature(for: parent.mode)

            let htmlToLoad: String
            switch parent.mode {
            case .scaledPreview(let scale):
                htmlToLoad = wrapWithScale(parent.htmlContent, scale: scale)
                let estimatedWidth = Int((HTMLPreviewScaleCalculator.estimatedLayoutWidth(from: parent.htmlContent) ?? 0).rounded())
                let scaleMilli = Int((scale * 1000).rounded())
                Log.diagnostic(
                    .htmlPreview,
                    "HTML_PREVIEW scale_milli=\(scaleMilli) estimated_width=\(estimatedWidth)",
                    category: .ui
                )
            case .fullInteractive, .simplePreview:
                htmlToLoad = parent.htmlContent
            }

            // Use sender domain as baseURL to provide correct Referer header for CDN images
            // (e.g., Beehiiv CDN checks Referer for hotlink protection)
            // Falls back to about:blank if no sender information available
            let baseURL = deriveBaseURL(from: parent.message) ?? URL(string: "about:blank")
            webView.loadHTMLString(htmlToLoad, baseURL: baseURL)
        }

        private func modeSignature(for mode: EmailWebViewMode) -> String {
            switch mode {
            case .fullInteractive:
                return "fullInteractive"
            case .simplePreview:
                return "simplePreview"
            case .scaledPreview(let scale):
                // Quantize to prevent unnecessary reloads from insignificant layout jitter.
                let quantized = Int((scale * 1000.0).rounded())
                return "scaledPreview:\(quantized)"
            }
        }

        /// Derives a baseURL from the sender's email domain for proper Referer headers
        private func deriveBaseURL(from message: Message?) -> URL? {
            EmailSenderBaseURLResolver.baseURL(from: message?.senderEmail)
        }

        private func wrapWithScale(_ html: String, scale: CGFloat) -> String {
            let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
            let bgColor = isDarkMode ? "#1c1c1e" : "#f2f2f7"

            // Avoid nesting full HTML documents inside another <html> wrapper; that can produce blank
            // previews or render only partial/head content. Instead, inject a tiny stylesheet that scales
            // the existing document when the input already contains <html>/<doctype>.
            if html.range(of: "<!doctype", options: .caseInsensitive) != nil ||
                html.range(of: "<html", options: .caseInsensitive) != nil {
                return injectScaleStyles(into: html, scale: scale)
            }

            // Partial fragments (no document structure): wrap in our own container.
            return wrapPartialHTMLWithScale(html, scale: scale, backgroundColor: bgColor)
        }

        private func injectScaleStyles(into html: String, scale: CGFloat) -> String {
            // Scale the rendered page without touching the email's DOM structure.
            // Keep rules minimal to avoid overriding the email's own layout/CSS.
            let injected = """
            <style id="esc-preview-scale">
                html, body { overflow: hidden !important; }
                /* Use higher specificity + !important so template body rules don't override preview scaling. */
                html body {
                    -webkit-text-size-adjust: 100% !important;
                    transform: scale(\(scale)) !important;
                    transform-origin: top left !important;
                    width: \(100.0 / scale)% !important;
                    min-width: 0 !important;
                }
                img { max-width: 100%; height: auto; }
                table { max-width: 100%; }
            </style>
            """

            // Don't double-inject if the HTML already contains our scale styles.
            if html.range(of: "id=\"esc-preview-scale\"", options: .caseInsensitive) != nil {
                return ensureDoctype(html)
            }

            var result = html

            if let headRange = result.range(of: "<head>", options: .caseInsensitive) {
                result.insert(contentsOf: "\n" + injected + "\n", at: headRange.upperBound)
                return ensureDoctype(result)
            }

            if let headStart = result.range(of: "<head", options: .caseInsensitive),
               let closing = result[headStart.lowerBound...].firstIndex(of: ">") {
                let insertIndex = result.index(after: closing)
                result.insert(contentsOf: "\n" + injected + "\n", at: insertIndex)
                return ensureDoctype(result)
            }

            // No <head>: inject one immediately after the opening <html ...> tag.
            if let htmlStart = result.range(of: "<html", options: .caseInsensitive),
               let closing = result[htmlStart.lowerBound...].firstIndex(of: ">") {
                let insertIndex = result.index(after: closing)
                result.insert(contentsOf: "\n<head>\n" + injected + "\n</head>\n", at: insertIndex)
                return ensureDoctype(result)
            }

            // Worst-case fallback: wrap as a fragment.
            let bgColor = UITraitCollection.current.userInterfaceStyle == .dark ? "#1c1c1e" : "#f2f2f7"
            return wrapPartialHTMLWithScale(result, scale: scale, backgroundColor: bgColor)
        }

        private func wrapPartialHTMLWithScale(_ html: String, scale: CGFloat, backgroundColor: String) -> String {
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
                <style>
                    * { box-sizing: border-box; }
                    html, body {
                        margin: 0;
                        padding: 0;
                        background-color: \(backgroundColor);
                        overflow: hidden;
                        -webkit-text-size-adjust: 100%;
                    }
                    .scale-wrapper {
                        transform: scale(\(scale));
                        transform-origin: top left;
                        width: \(100.0 / scale)%;
                    }
                    /* Only constrain, don't force widths */
                    img { max-width: 100%; height: auto; }
                    table { max-width: 100%; }
                </style>
            </head>
            <body>
                <div class="scale-wrapper">
                    \(html)
                </div>
            </body>
            </html>
            """
        }

        private func ensureDoctype(_ html: String) -> String {
            if html.range(of: "<!doctype", options: .caseInsensitive) != nil {
                return html
            }
            return "<!DOCTYPE html>\n" + html
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            switch parent.mode {
            case .fullInteractive:
                handleFullInteractiveNavigation(navigationAction, decisionHandler: decisionHandler)
            case .scaledPreview, .simplePreview:
                handlePreviewNavigation(navigationAction, decisionHandler: decisionHandler)
            }
        }

        private func handleFullInteractiveNavigation(_ navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow initial load and resource loads first (before other checks)
            // This is critical for loadHTMLString with about:blank baseURL
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url {
                let urlString = url.absoluteString

                // Block obviously malformed URLs
                if urlString.isEmpty || urlString == "about:blank" {
                    decisionHandler(.cancel)
                    return
                }

                // Block unsupported schemes that cause errors
                // Note: "cid" is NOT blocked - it's handled by CIDSchemeHandler
                let scheme = url.scheme?.lowercased() ?? ""
                let unsupportedSchemes = ["javascript", "vbscript", "file", "x-apple-data-detectors"]
                if unsupportedSchemes.contains(scheme) {
                    decisionHandler(.cancel)
                    return
                }
            }

            // Handle link clicks
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // Don't open localhost links
                if url.host != "localhost" && url.scheme?.hasPrefix("http") == true {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func handlePreviewNavigation(_ navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only allow initial load and reload for previews
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            Log.debug("WebView navigation failed: \(error)", category: .ui)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            Log.debug("WebView provisional navigation failed: \(error)", category: .ui)
        }
    }
}
