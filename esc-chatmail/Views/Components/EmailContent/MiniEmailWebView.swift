import SwiftUI

/// A scaled-down WKWebView that shows a preview of HTML email content
/// Wraps BaseEmailWebView with scaledPreview mode
struct MiniEmailWebView: View {
    let htmlContent: String
    var scale: CGFloat = 0.5

    var body: some View {
        BaseEmailWebView(
            htmlContent: htmlContent,
            mode: .scaledPreview(scale: scale)
        )
    }
}
