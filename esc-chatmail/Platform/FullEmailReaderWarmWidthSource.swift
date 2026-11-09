import CoreGraphics

/// The width visible-row warming pre-renders the full reader at. A pre-rendered WebView is adopted
/// only when its width matches the reader's exactly (`FullEmailWebViewPreRenderKey.widthBucket`),
/// so this has to predict the reader's width before the reader opens.
@MainActor
enum FullEmailReaderWarmWidthSource {
    /// iOS: the active scene's screen width, which is the width of the reader sheet on an iPhone.
    ///
    /// Mac: the width the reader last laid out at, or nil before the first open (rows then warm
    /// only the prepared HTML, not a WebView). A Mac screen is far wider than the reader, so a
    /// WebView warmed at screen width would never match a checkout. Resizing the window changes the
    /// reader's width; the next open records the new width, and rows warm at it from then on.
    static var currentWidth: CGFloat? {
        #if canImport(UIKit)
        FullEmailWebViewMetrics.activeWindowScene()?.screen.bounds.width
        #else
        lastMeasuredReaderWidth
        #endif
    }

    /// The width `FullEmailOpenSession` last measured for an open reader. It is recorded on both
    /// platforms, but only the Mac reads it. A width is not account data, so it survives sign-out.
    private(set) static var lastMeasuredReaderWidth: CGFloat?

    static func recordMeasuredReaderWidth(_ width: CGFloat) {
        guard width.isFinite, width > 1 else {
            return
        }
        lastMeasuredReaderWidth = width
    }

    static func resetForTesting() {
        lastMeasuredReaderWidth = nil
    }
}
