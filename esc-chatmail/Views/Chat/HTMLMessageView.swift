import SwiftUI
import WebKit

// MARK: - Inline HTML Preview for Chat Bubbles
struct HTMLPreviewView: View {
    let message: Message
    let maxHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true

    private let htmlContentLoader = HTMLContentLoader.shared

    var body: some View {
        Group {
            if isLoading {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: maxHeight)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                    )
            } else if let html = htmlContent {
                HTMLPreviewWebView(
                    htmlContent: html,
                    isDarkMode: colorScheme == .dark,
                    maxHeight: maxHeight
                )
                .frame(height: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 60)
                    .overlay(
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }
        }
        .task {
            await loadHTMLContent()
        }
    }

    private func loadHTMLContent() async {
        let result = await htmlContentLoader.loadContent(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            isDarkMode: colorScheme == .dark
        )

        await MainActor.run {
            self.htmlContent = result.html
            self.isLoading = false
        }
    }
}

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

// MARK: - Full HTML Message View
struct HTMLMessageView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true

    private let htmlContentLoader = HTMLContentLoader.shared

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html = htmlContent {
                    HTMLWebView(
                        htmlContent: html,
                        isDarkMode: colorScheme == .dark
                    )
                } else {
                    ContentUnavailableView(
                        "No Content",
                        systemImage: "doc.text",
                        description: Text("The original email content is not available")
                    )
                }
            }
            .navigationTitle("Original Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadHTMLContent()
        }
    }

    private func loadHTMLContent() async {
        let result = await htmlContentLoader.loadContentWithTimeout(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            isDarkMode: colorScheme == .dark,
            timeout: 5.0
        )

        // Handle URI migration if loaded from messageId but URI was stale
        if result.source == .messageId,
           let context = message.managedObjectContext {
            let messageId = message.id
            Task {
                await context.perform {
                    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let messagesDirectory = documentsPath.appendingPathComponent("Messages")
                    let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
                    message.bodyStorageURI = fileURL.absoluteString
                    try? context.save()
                }
            }
        }

        await MainActor.run {
            self.htmlContent = result.html
            self.isLoading = false
        }
    }
}

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

            /* JavaScript injection disabled for security - keeping for reference
            let jsCode = """
                // Comprehensive image error handling for modern formats
                var images = document.getElementsByTagName('img');
                var unsupportedFormats = ['.webp', '.avif', '.jxl', '.heic', '.heif'];

                for (var i = 0; i < images.length; i++) {
                    var img = images[i];

                    // Store original display style
                    if (!img.dataset.originalDisplay) {
                        img.dataset.originalDisplay = img.style.display || 'inline';
                    }

                    // Add error handler
                    img.onerror = function() {
                        var src = this.src || '';
                        var isUnsupportedFormat = false;

                        // Check if it's an unsupported format
                        for (var j = 0; j < unsupportedFormats.length; j++) {
                            if (src.toLowerCase().includes(unsupportedFormats[j])) {
                                isUnsupportedFormat = true;
                                break;
                            }
                        }

                        if (isUnsupportedFormat) {
                            // For unsupported formats, hide immediately
                            this.style.display = 'none';
                            this.alt = this.alt || 'Image format not supported';
                        } else if (!this.dataset.retryCount || parseInt(this.dataset.retryCount) < 1) {
                            // Try reloading once for other formats
                            this.dataset.retryCount = (parseInt(this.dataset.retryCount) || 0) + 1;
                            var originalSrc = this.src;
                            this.src = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
                            setTimeout(function(img, src) {
                                img.src = src;
                            }.bind(null, this, originalSrc), 100);
                        } else {
                            // Hide after retry failed
                            this.style.display = 'none';
                        }
                        this.onerror = null; // Prevent infinite loop
                    };

                    // Check for modern format support proactively
                    var src = img.src || '';
                    if (src) {
                        for (var j = 0; j < unsupportedFormats.length; j++) {
                            if (src.toLowerCase().includes(unsupportedFormats[j])) {
                                // Test format support
                                var format = unsupportedFormats[j].substring(1);
                                if (!window['supports_' + format]) {
                                    // Format likely unsupported, trigger error handler
                                    img.onerror();
                                }
                                break;
                            }
                        }
                    }

                    // Check if image failed to load initially
                    if (img.complete && img.naturalWidth === 0) {
                        img.onerror();
                    }
                }

                // Ensure proper viewport scaling
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes';
                    document.head.appendChild(meta);
                }

                // Suppress console errors for unsupported image formats
                window.addEventListener('error', function(e) {
                    if (e.target && e.target.tagName === 'IMG') {
                        var src = e.target.src || '';
                        // Don't log errors for known unsupported formats
                        var isUnsupported = false;
                        for (var i = 0; i < unsupportedFormats.length; i++) {
                            if (src.toLowerCase().includes(unsupportedFormats[i])) {
                                isUnsupported = true;
                                break;
                            }
                        }
                        if (!isUnsupported) {
                            console.log('Image load error:', src);
                        }
                        e.target.style.display = 'none';
                        e.preventDefault(); // Prevent error propagation
                    }
                }, true);
            """
            webView.evaluateJavaScript(jsCode, completionHandler: nil)
            */
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