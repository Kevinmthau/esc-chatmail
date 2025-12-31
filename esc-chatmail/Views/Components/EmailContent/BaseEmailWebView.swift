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

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

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
            webView.scrollView.contentInsetAdjustmentBehavior = .automatic
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
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
        if context.coordinator.lastLoadedContent != htmlContent {
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
        private var isLoading = false

        init(_ parent: BaseEmailWebView) {
            self.parent = parent
        }

        func loadContent(in webView: WKWebView) {
            guard !isLoading else { return }
            isLoading = true
            lastLoadedContent = parent.htmlContent

            let htmlToLoad: String
            switch parent.mode {
            case .scaledPreview(let scale):
                htmlToLoad = wrapWithScale(parent.htmlContent, scale: scale)
            case .fullInteractive, .simplePreview:
                htmlToLoad = parent.htmlContent
            }

            let baseURL = URL(string: "https://localhost/")
            webView.loadHTMLString(htmlToLoad, baseURL: baseURL)
        }

        private func wrapWithScale(_ html: String, scale: CGFloat) -> String {
            let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
            let bgColor = isDarkMode ? "#1c1c1e" : "#f2f2f7"
            let textColor = isDarkMode ? "#ffffff" : "#000000"
            let linkColor = isDarkMode ? "#0a84ff" : "#007aff"

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
                        background-color: \(bgColor);
                        color: \(textColor);
                        overflow: hidden;
                    }
                    .scale-wrapper {
                        transform: scale(\(scale));
                        transform-origin: top left;
                        width: \(100.0 / scale)%;
                    }
                    img { max-width: 100% !important; height: auto !important; }
                    table { max-width: 100% !important; }
                    a { color: \(linkColor); }
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
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString

                // Block obviously malformed URLs
                if urlString.isEmpty || urlString == "about:blank" {
                    decisionHandler(.cancel)
                    return
                }

                // Block unsupported schemes that cause errors
                let scheme = url.scheme?.lowercased() ?? ""
                let unsupportedSchemes = ["javascript", "vbscript", "file", "x-apple-data-detectors", "cid"]
                if unsupportedSchemes.contains(scheme) {
                    decisionHandler(.cancel)
                    return
                }
            }

            // Allow initial load and resource loads
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
                return
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
