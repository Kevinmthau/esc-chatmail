import SwiftUI

/// Full interactive WebView for displaying original email HTML.
struct HTMLWebView: View {
    let htmlContent: String
    let isDarkMode: Bool
    var senderEmail: String? = nil
    var sourceSignature: String? = nil
    var readerWidth: CGFloat = 0
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?
    var webViewAdoptionProvider: (any FullEmailWebViewAdopting)?
    /// Invoked when the WebView reports paint-confirmed readiness, so the reader can cross-fade its placeholder.
    var onLoadFinished: (() -> Void)? = nil
    /// Invoked when the live navigation fails, so the reader can restore its placeholder.
    var onLoadFailed: (() -> Void)? = nil
    /// Invoked when the guarded pre-render adoption path supplies an already-painted WebView, so the
    /// reader can drop its placeholder instantly.
    var onAdoptedPrerendered: (() -> Void)? = nil

    var body: some View {
        FullEmailReaderWebView(
            htmlContent: htmlContent,
            sourceSignature: sourceSignature,
            readerWidth: readerWidth,
            message: message,
            webViewAdoptionProvider: webViewAdoptionProvider,
            onLoadFinished: onLoadFinished,
            onLoadFailed: onLoadFailed,
            onAdoptedPrerendered: onAdoptedPrerendered
        )
    }
}
