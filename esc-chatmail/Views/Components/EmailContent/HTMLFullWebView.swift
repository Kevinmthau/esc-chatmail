import SwiftUI

/// Full interactive WebView for displaying email HTML content
/// Wraps BaseEmailWebView with fullInteractive mode
struct HTMLWebView: View {
    let htmlContent: String
    let isDarkMode: Bool
    var senderEmail: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?

    var body: some View {
        BaseEmailWebView(
            htmlContent: htmlContent,
            mode: .fullInteractive,
            isDarkMode: isDarkMode,
            senderEmail: senderEmail,
            message: message
        )
    }
}
