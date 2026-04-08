import SwiftUI

/// A scaled-down WKWebView that shows a preview of HTML email content.
/// Keep newsletter chat previews out of this path; they should use the derived native preview card.
struct MiniEmailWebView: View {
    let htmlContent: String
    var scale: CGFloat = 0.5
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?

    var body: some View {
        GeometryReader { geometry in
            let adaptiveScale = HTMLPreviewScaleCalculator.previewScale(
                defaultScale: scale,
                containerWidth: geometry.size.width,
                html: htmlContent
            )

            BaseEmailWebView(
                htmlContent: htmlContent,
                mode: .scaledPreview(scale: adaptiveScale),
                message: message
            )
        }
    }
}
