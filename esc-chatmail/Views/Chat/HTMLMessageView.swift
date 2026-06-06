import SwiftUI

// MARK: - Full HTML Message View

/// Rendering-only surface for already-loaded original-email HTML.
struct HTMLMessageView: View {
    let message: Message
    let html: String
    let sourceSignature: String?
    let readerWidth: CGFloat
    let webViewAdoptionProvider: (any FullEmailWebViewAdopting)?
    var onLoadFinished: (() -> Void)?
    var onAdoptedPrerendered: (() -> Void)?

    var body: some View {
        HTMLWebView(
            htmlContent: html,
            isDarkMode: false,
            sourceSignature: sourceSignature,
            readerWidth: readerWidth,
            message: message,
            webViewAdoptionProvider: webViewAdoptionProvider,
            onLoadFinished: onLoadFinished,
            onAdoptedPrerendered: onAdoptedPrerendered
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
