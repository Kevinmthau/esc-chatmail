import SwiftUI

/// A non-interactive WebView for previewing HTML content
/// Wraps BaseEmailWebView with simplePreview mode
struct HTMLPreviewWebView: View {
    let htmlContent: String
    let isDarkMode: Bool
    let maxHeight: CGFloat

    var body: some View {
        BaseEmailWebView(
            htmlContent: htmlContent,
            mode: .simplePreview,
            isDarkMode: isDarkMode
        )
        .frame(maxHeight: maxHeight)
    }
}
