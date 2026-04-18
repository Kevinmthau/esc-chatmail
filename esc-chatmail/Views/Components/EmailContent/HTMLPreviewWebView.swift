import SwiftUI

/// A non-interactive WebView for previewing HTML content
/// Wraps BaseEmailWebView with simplePreview mode
struct HTMLPreviewWebView: View {
    let htmlContent: String
    let isDarkMode: Bool
    let maxHeight: CGFloat
    var senderEmail: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?

    var body: some View {
        BaseEmailWebView(
            htmlContent: htmlContent,
            mode: .simplePreview,
            isDarkMode: isDarkMode,
            senderEmail: senderEmail,
            message: message
        )
        .frame(maxHeight: maxHeight)
    }
}
