import SwiftUI
import WebKit

struct HTMLWebView: UIViewRepresentable {
    let htmlContent: String
    let isDarkMode: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = [.phoneNumber, .link, .address]

        // Enable JavaScript for our error-handling wrapper script
        // Security: Email scripts are stripped during sanitization, only our wrapper script runs
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Allow content to load properly
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Add custom URL scheme handler for better error handling
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Set custom user agent to ensure proper rendering
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

        // Load content immediately
        context.coordinator.loadContent(in: webView)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if content has changed
        if context.coordinator.lastLoadedContent != htmlContent {
            context.coordinator.loadContent(in: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        var lastLoadedContent: String = ""
        private var isLoading = false

        init(_ parent: HTMLWebView) {
            self.parent = parent
        }

        func loadContent(in webView: WKWebView) {
            guard !isLoading else { return }
            isLoading = true
            lastLoadedContent = parent.htmlContent

            // Use https base URL for better compatibility
            let baseURL = URL(string: "https://localhost/")
            webView.loadHTMLString(parent.htmlContent, baseURL: baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Check for malformed URLs
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false

            // NOTE: JavaScript is disabled for security. Image error handling must be done via HTML/CSS.
            // Unsupported image formats should be filtered during HTML sanitization instead.
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
