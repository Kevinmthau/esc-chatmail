import SwiftUI

/// Full interactive WebView for displaying email HTML content
/// Wraps BaseEmailWebView with fullInteractive mode
struct HTMLWebView: View {
    let htmlContent: String
    let isDarkMode: Bool
    var senderEmail: String? = nil
    var sourceSignature: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?
    /// Invoked when the WebView finishes its first paint, so the reader can cross-fade its placeholder.
    var onLoadFinished: (() -> Void)? = nil
    /// Invoked when the guarded pre-render adoption path supplies an already-painted WebView, so the
    /// reader can drop its placeholder instantly.
    var onAdoptedPrerendered: (() -> Void)? = nil

    var body: some View {
        BaseEmailWebView(
            htmlContent: htmlContent,
            mode: .fullInteractive,
            isDarkMode: isDarkMode,
            senderEmail: senderEmail,
            sourceSignature: sourceSignature,
            message: message,
            onLoadFinished: onLoadFinished,
            onAdoptedPrerendered: onAdoptedPrerendered
        )
    }
}
