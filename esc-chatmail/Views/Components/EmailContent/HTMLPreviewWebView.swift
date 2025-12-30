import SwiftUI
import WebKit

struct HTMLPreviewWebView: UIViewRepresentable {
    let htmlContent: String
    let isDarkMode: Bool
    let maxHeight: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

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

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLPreviewWebView
        var lastLoadedContent: String = ""

        init(_ parent: HTMLPreviewWebView) {
            self.parent = parent
        }

        func loadContent(in webView: WKWebView) {
            lastLoadedContent = parent.htmlContent
            let baseURL = URL(string: "https://localhost/")
            webView.loadHTMLString(parent.htmlContent, baseURL: baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
