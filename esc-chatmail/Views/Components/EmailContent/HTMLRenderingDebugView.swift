#if DEBUG
import SwiftUI
import WebKit

/// Debug view for testing HTML email rendering
/// Paste raw HTML and compare "Before" (raw) vs "After" (processed) rendering
struct HTMLRenderingDebugView: View {
    @State private var rawHTML: String = ""
    @State private var showingRaw = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var isDarkMode: Bool { colorScheme == .dark }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Toggle between raw and processed
                Picker("View Mode", selection: $showingRaw) {
                    Text("Processed (App)").tag(false)
                    Text("Raw (Original)").tag(true)
                }
                .pickerStyle(.segmented)
                .padding()

                // WebView showing the HTML
                if rawHTML.isEmpty {
                    ContentUnavailableView(
                        "Paste HTML to Test",
                        systemImage: "doc.text",
                        description: Text("Tap the paste button or edit the HTML directly")
                    )
                } else {
                    HTMLDebugWebView(
                        html: showingRaw ? rawHTML : processedHTML,
                        isDarkMode: isDarkMode
                    )
                }
            }
            .navigationTitle("HTML Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Paste from Clipboard") {
                            if let text = UIPasteboard.general.string {
                                rawHTML = text
                            }
                        }
                        Button("Edit HTML") {
                            // Show editor
                        }
                        Button("Clear") {
                            rawHTML = ""
                        }
                        Divider()
                        Button("Load Sample Newsletter") {
                            rawHTML = sampleNewsletterHTML
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var processedHTML: String {
        HTMLSanitizerService.shared.wrapHTMLForDisplay(rawHTML, isDarkMode: isDarkMode)
    }

    // Sample newsletter HTML for testing
    private var sampleNewsletterHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                @media only screen and (max-width: 600px) {
                    .container { width: 100% !important; }
                    .product-cell { width: 50% !important; display: inline-block !important; }
                }
            </style>
        </head>
        <body style="margin: 0; padding: 0; background-color: #f4f4f4;">
            <table width="600" cellpadding="0" cellspacing="0" border="0" align="center" class="container" style="background-color: #ffffff;">
                <tr>
                    <td style="padding: 20px; text-align: center;">
                        <h1 style="color: #333; font-family: Arial, sans-serif;">Newsletter</h1>
                    </td>
                </tr>
                <tr>
                    <td style="padding: 0 20px;">
                        <table width="100%" cellpadding="0" cellspacing="0">
                            <tr>
                                <td width="50%" class="product-cell" style="padding: 10px; vertical-align: top;">
                                    <div style="background: #f9f9f9; padding: 15px; text-align: center;">
                                        <div style="width: 100%; height: 150px; background: #ddd;"></div>
                                        <p style="color: #333; font-family: Arial; margin: 10px 0;">Product One</p>
                                        <p style="color: #666; font-family: Arial; font-size: 14px;">$99.00</p>
                                    </div>
                                </td>
                                <td width="50%" class="product-cell" style="padding: 10px; vertical-align: top;">
                                    <div style="background: #f9f9f9; padding: 15px; text-align: center;">
                                        <div style="width: 100%; height: 150px; background: #ddd;"></div>
                                        <p style="color: #333; font-family: Arial; margin: 10px 0;">Product Two</p>
                                        <p style="color: #666; font-family: Arial; font-size: 14px;">$149.00</p>
                                    </div>
                                </td>
                            </tr>
                        </table>
                    </td>
                </tr>
            </table>
        </body>
        </html>
        """
    }
}

/// Simple WebView for debug rendering
private struct HTMLDebugWebView: UIViewRepresentable {
    let html: String
    let isDarkMode: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Use about:blank baseURL to provide URL resolution context while avoiding Referer header issues
        webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
    }
}

#Preview {
    HTMLRenderingDebugView()
}
#endif
