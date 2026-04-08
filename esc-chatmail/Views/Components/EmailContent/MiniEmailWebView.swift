import SwiftUI

/// A scaled-down WKWebView that shows a preview of HTML email content.
/// Keep newsletter chat previews out of this path; they should use the derived native preview card.
struct MiniEmailWebView: View {
    let htmlContent: String
    var scale: CGFloat = 0.5
    var isDarkMode: Bool = false
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?
    @State private var measuredHeight = Self.defaultPreviewHeight

    private static let defaultPreviewHeight: CGFloat = 180
    private static let minimumPreviewHeight: CGFloat = 120
    private static let maximumPreviewHeight: CGFloat = 320

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
                isDarkMode: isDarkMode,
                message: message,
                onPreviewHeightChange: updateMeasuredHeight
            )
        }
        .frame(height: clampedPreviewHeight)
    }

    private var clampedPreviewHeight: CGFloat {
        min(max(measuredHeight, Self.minimumPreviewHeight), Self.maximumPreviewHeight)
    }

    private func updateMeasuredHeight(_ height: CGFloat) {
        let clampedHeight = min(max(height, Self.minimumPreviewHeight), Self.maximumPreviewHeight)
        guard abs(clampedHeight - measuredHeight) > 1 else {
            return
        }

        measuredHeight = clampedHeight
    }
}
