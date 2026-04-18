import Foundation
import SwiftUI

/// A scaled-down WKWebView that shows a preview of HTML email content.
/// Keep newsletter chat previews out of this path; they should use the derived native preview card.
struct MiniEmailWebView: View {
    let htmlContent: String
    let previewCacheKey: String?
    var scale: CGFloat = 0.5
    var isDarkMode: Bool = false
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?
    @State private var measuredHeight: CGFloat

    private let previewHeightCacheKey: String

    private static let defaultPreviewHeight: CGFloat = 180
    private static let minimumPreviewHeight: CGFloat = 120
    private static let maximumPreviewHeight: CGFloat = 320
    private static let previewHeightCache = MiniEmailPreviewHeightCache()

    init(
        htmlContent: String,
        previewCacheKey: String? = nil,
        scale: CGFloat = 0.5,
        isDarkMode: Bool = false,
        message: Message? = nil
    ) {
        self.htmlContent = htmlContent
        self.previewCacheKey = previewCacheKey
        self.scale = scale
        self.isDarkMode = isDarkMode
        self.message = message
        self.previewHeightCacheKey = previewCacheKey ?? Self.previewHeightCacheKey(
            messageID: message?.id,
            htmlContent: htmlContent
        )
        self._measuredHeight = State(
            initialValue: Self.cachedPreviewHeight(for: self.previewHeightCacheKey)
        )
    }

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
        .onChange(of: previewHeightCacheKey) { _, newValue in
            measuredHeight = Self.cachedPreviewHeight(for: newValue)
        }
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
        Self.previewHeightCache.setHeight(clampedHeight, forKey: previewHeightCacheKey)
    }

    private static func previewHeightCacheKey(messageID: String?, htmlContent: String) -> String {
        let fingerprint = String(htmlContent.hashValue)
        if let messageID, !messageID.isEmpty {
            return "\(messageID)|\(fingerprint)"
        }
        return "html|\(fingerprint)"
    }

    private static func cachedPreviewHeight(for key: String) -> CGFloat {
        let cachedHeight = previewHeightCache.height(forKey: key) ?? defaultPreviewHeight
        return min(max(cachedHeight, minimumPreviewHeight), maximumPreviewHeight)
    }
}

private final class MiniEmailPreviewHeightCache {
    private let cache = NSCache<NSString, NSNumber>()

    init() {
        cache.countLimit = 256
    }

    func height(forKey key: String) -> CGFloat? {
        guard let value = cache.object(forKey: key as NSString) else {
            return nil
        }
        return CGFloat(value.doubleValue)
    }

    func setHeight(_ height: CGFloat, forKey key: String) {
        cache.setObject(NSNumber(value: Double(height)), forKey: key as NSString)
    }
}
