import SwiftUI
import WebKit

/// A scaled-down WKWebView that shows a preview of HTML email content
struct MiniEmailWebView: UIViewRepresentable {
    let htmlContent: String
    var scale: CGFloat = 0.5

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .secondarySystemBackground
        webView.scrollView.backgroundColor = .secondarySystemBackground

        // Load initial content
        context.coordinator.loadContent(in: webView, html: htmlContent, scale: scale)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if content changed
        if context.coordinator.lastLoadedContent != htmlContent {
            context.coordinator.loadContent(in: webView, html: htmlContent, scale: scale)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedContent: String = ""

        func loadContent(in webView: WKWebView, html: String, scale: CGFloat) {
            lastLoadedContent = html
            let wrappedHTML = wrapWithScale(html, scale: scale)
            webView.loadHTMLString(wrappedHTML, baseURL: URL(string: "https://localhost/"))
        }

        private func wrapWithScale(_ html: String, scale: CGFloat) -> String {
            let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
            let bgColor = isDarkMode ? "#1c1c1e" : "#f2f2f7"
            let textColor = isDarkMode ? "#ffffff" : "#000000"

            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
                <style>
                    * {
                        box-sizing: border-box;
                    }
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
                    img {
                        max-width: 100% !important;
                        height: auto !important;
                    }
                    table {
                        max-width: 100% !important;
                    }
                    a {
                        color: \(isDarkMode ? "#0a84ff" : "#007aff");
                    }
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

        // Block all navigation (it's a preview only)
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
