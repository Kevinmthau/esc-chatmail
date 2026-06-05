import SwiftUI
import UIKit
import WebKit

// `LayoutAwareWKWebView` lives in `FullEmailWebViewManager.swift` so preview WebViews, the full
// reader, and the pre-rendered pool can share a single layout-reporting WebView type.

/// Configuration mode for non-interactive email preview rendering.
enum EmailWebViewMode {
    /// Scaled preview (e.g., 50%) with no interaction.
    ///
    /// Preview modes follow the preview policy: the wrapped HTML and native
    /// background adapt to the app appearance while keeping authored colors where possible.
    case scaledPreview(scale: CGFloat)
    /// Simple non-interactive preview at full size.
    ///
    /// Preview modes leave the WebView trait style unspecified so CSS can resolve
    /// against the surrounding app appearance.
    case simplePreview
}

extension EmailWebViewMode {
    var displayPurpose: HTMLDisplayPurpose {
        .preview
    }

    var webViewUserInterfaceStyle: UIUserInterfaceStyle {
        .unspecified
    }
}

/// Unified preview WebView for rendering non-interactive email HTML content.
/// Used by compose previews and the MiniEmailWebView snapshot-failure fallback.
struct BaseEmailWebView: UIViewRepresentable {
    let htmlContent: String
    let mode: EmailWebViewMode
    var isDarkMode: Bool? = nil
    var senderEmail: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments.
    var message: Message?
    /// Optional callback for non-interactive previews that need their rendered height.
    var onPreviewHeightChange: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        makePreviewUIView(context: context)
    }

    private func makePreviewUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Register cid: scheme handler for inline attachments.
        let cidHandler = CIDSchemeHandler(message: message)
        context.coordinator.cidHandler = cidHandler
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = LayoutAwareWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.onLayoutChange = { [weak coordinator = context.coordinator] webView in
            coordinator?.loadContentIfReady(in: webView)
        }

        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false

        context.coordinator.applyBackgroundAppearance(to: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateParent(self)
        context.coordinator.applyBackgroundAppearance(to: webView)
        context.coordinator.loadContentIfReady(in: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        enum LoadReadiness: Equatable {
            case ready
            case deferred(reason: String)
        }

        var parent: BaseEmailWebView
        var lastLoadedContent: String = ""
        var lastLoadedReloadSignature: String = ""
        private var isLoading = false
        private var hasFinishedLoad = false
        private var shouldReloadAfterCurrentLoad = false
        private var lastDeliveredPreviewHeight: CGFloat = 0
        private var previewMeasurementGeneration = 0
        /// Holds strong reference to the cid: scheme handler.
        var cidHandler: CIDSchemeHandler?

        init(_ parent: BaseEmailWebView) {
            self.parent = parent
        }

        var needsReload: Bool {
            lastLoadedContent != parent.htmlContent || lastLoadedReloadSignature != reloadSignature()
        }

        func updateParent(_ parent: BaseEmailWebView) {
            self.parent = parent
            cidHandler?.message = parent.message
        }

        func loadContent(in webView: WKWebView) {
            guard !isLoading else { return }
            isLoading = true
            shouldReloadAfterCurrentLoad = false
            lastDeliveredPreviewHeight = 0
            previewMeasurementGeneration &+= 1
            recordLoadedSignature()

            let htmlToLoad: String
            switch parent.mode {
            case .scaledPreview(let scale):
                htmlToLoad = wrapWithScale(parent.htmlContent, scale: scale)
                let estimatedWidth = Int((HTMLPreviewScaleCalculator.estimatedLayoutWidth(from: parent.htmlContent) ?? 0).rounded())
                let scaleMilli = Int((scale * 1000).rounded())
                Log.diagnostic(
                    .htmlPreview,
                    "HTML_PREVIEW scale_milli=\(scaleMilli) estimated_width=\(estimatedWidth)",
                    category: .ui
                )
            case .simplePreview:
                htmlToLoad = parent.htmlContent
            }

            // Use sender domain as baseURL to provide correct Referer header for CDN images
            // (e.g., Beehiiv CDN checks Referer for hotlink protection). Falls back to about:blank.
            let baseURL = deriveBaseURL(from: parent.message, senderEmail: parent.senderEmail) ?? URL(string: "about:blank")
            webView.loadHTMLString(htmlToLoad, baseURL: baseURL)
        }

        func loadContentIfReady(in webView: WKWebView) {
            let windowPresent = webView.window != nil
            let width = webView.bounds.width
            let height = webView.bounds.height

            switch loadReadiness(windowPresent: windowPresent, width: width, height: height) {
            case .ready:
                loadContent(in: webView)
            case .deferred(let reason):
                logDeferredLoad(
                    reason: reason,
                    windowPresent: windowPresent,
                    width: width,
                    height: height
                )
                return
            }
        }

        func loadReadiness(windowPresent: Bool, width: CGFloat, height: CGFloat) -> LoadReadiness {
            guard needsReload else {
                return .deferred(reason: "no-pending-reload")
            }

            guard !isLoading else {
                return .deferred(reason: "already-loading")
            }

            guard windowPresent else {
                return .deferred(reason: "missing-window")
            }

            guard width > 1 else {
                return .deferred(reason: "missing-width")
            }

            guard height > 1 else {
                return .deferred(reason: "missing-height")
            }

            return .ready
        }

        private func logDeferredLoad(
            reason: String,
            windowPresent: Bool,
            width: CGFloat,
            height: CGFloat
        ) {
            guard needsReload || isLoading else {
                return
            }

            Log.diagnostic(
                .htmlPreview,
                level: .debug,
                "BaseEmailWebView deferredLoad reason=\(reason) mode=\(readinessModeDescription()) messageId=\(parent.message?.id ?? "nil") windowPresent=\(windowPresent) width=\(String(format: "%.1f", width)) height=\(String(format: "%.1f", height)) needsReload=\(needsReload) isLoading=\(isLoading)",
                category: .ui
            )
        }

        func recordLoadedSignature() {
            lastLoadedContent = parent.htmlContent
            lastLoadedReloadSignature = reloadSignature()
            hasFinishedLoad = false
        }

        func recordFinishedLoad() {
            hasFinishedLoad = true
        }

        func resetLoadedSignatureAfterFailure() {
            lastLoadedContent = ""
            lastLoadedReloadSignature = ""
            hasFinishedLoad = false
        }

        func resetLoadedSignatureAfterFailure(for error: Error) {
            if isCancelledNavigationError(error), hasFinishedLoad {
                return
            }
            resetLoadedSignatureAfterFailure()
        }

        private func isCancelledNavigationError(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return true
            }

            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return isCancelledNavigationError(underlyingError)
            }

            return false
        }

        func applyBackgroundAppearance(to webView: WKWebView) {
            webView.isOpaque = false
            webView.overrideUserInterfaceStyle = parent.mode.webViewUserInterfaceStyle
            let backgroundColor = nativeBackgroundColor(for: parent.mode) ?? .clear
            webView.backgroundColor = backgroundColor
            webView.scrollView.backgroundColor = backgroundColor
            webView.underPageBackgroundColor = backgroundColor
        }

        private func reloadSignature() -> String {
            "\(modeSignature(for: parent.mode)):\(messageIdentitySignature()):source:none:cid:unchanged"
        }

        private func messageIdentitySignature() -> String {
            guard let message = parent.message else {
                return "message:none"
            }
            return "message:\(message.id)"
        }

        private func modeSignature(for mode: EmailWebViewMode) -> String {
            let colorSchemeSignature: String
            switch parent.isDarkMode {
            case true:
                colorSchemeSignature = "dark"
            case false:
                colorSchemeSignature = "light"
            case nil:
                colorSchemeSignature = "unspecified"
            }
            switch mode {
            case .simplePreview:
                return "simplePreview:\(colorSchemeSignature)"
            case .scaledPreview(let scale):
                // Quantize to prevent unnecessary reloads from insignificant layout jitter.
                let quantized = Int((scale * 1000.0).rounded())
                return "scaledPreview:\(quantized):\(colorSchemeSignature)"
            }
        }

        private func readinessModeDescription() -> String {
            switch parent.mode {
            case .simplePreview:
                return "simplePreview"
            case .scaledPreview(let scale):
                return "scaledPreview:\(String(format: "%.3f", scale))"
            }
        }

        private func nativeBackgroundColor(for mode: EmailWebViewMode) -> UIColor? {
            if case .simplePreview = mode, parent.isDarkMode == nil {
                // Preserve the old transparent simple-preview surface unless the caller opts into theming.
                return .clear
            }

            let theme = HTMLDisplayWrapper.theme(
                isDarkMode: parent.isDarkMode ?? false,
                displayPurpose: mode.displayPurpose
            )
            return UIColor(hex: theme.backgroundColorHex) ?? .systemBackground
        }

        /// Derives a baseURL from the sender's email domain for proper Referer headers.
        private func deriveBaseURL(from message: Message?, senderEmail: String?) -> URL? {
            EmailSenderBaseURLResolver.baseURL(from: message?.senderEmail ?? senderEmail)
        }

        private func wrapWithScale(_ html: String, scale: CGFloat) -> String {
            HTMLPreviewScalingWrapper.wrap(html, scale: scale)
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only allow initial load and reload for previews.
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            recordFinishedLoad()
            schedulePreviewHeightMeasurement(
                in: webView,
                generation: previewMeasurementGeneration
            )
            reloadAfterCurrentLoadIfNeeded(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            resetLoadedSignatureAfterFailure(for: error)
            Log.debug("WebView navigation failed: \(error)", category: .ui)
            reloadAfterCurrentLoadIfNeeded(in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            resetLoadedSignatureAfterFailure(for: error)
            Log.debug("WebView provisional navigation failed: \(error)", category: .ui)
            reloadAfterCurrentLoadIfNeeded(in: webView)
        }

        private func reloadAfterCurrentLoadIfNeeded(in webView: WKWebView) {
            guard shouldReloadAfterCurrentLoad else {
                return
            }

            shouldReloadAfterCurrentLoad = false
            loadContentIfReady(in: webView)
        }

        private func schedulePreviewHeightMeasurement(
            in webView: WKWebView,
            generation: Int
        ) {
            guard case .scaledPreview = parent.mode,
                  parent.onPreviewHeightChange != nil else {
                return
            }

            for delay in [DispatchTimeInterval.milliseconds(250), .seconds(1)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self,
                          let webView,
                          generation == self.previewMeasurementGeneration else {
                        return
                    }
                    self.measurePreviewHeight(in: webView, generation: generation)
                }
            }
        }

        private func measurePreviewHeight(
            in webView: WKWebView,
            generation: Int
        ) {
            guard case .scaledPreview(let scale) = parent.mode else {
                return
            }

            let measurementScript = HTMLPreviewHeightMeasurementScript.script(scale: scale)

            webView.evaluateJavaScript(measurementScript) { [weak self] result, error in
                guard let self else {
                    return
                }
                guard generation == self.previewMeasurementGeneration else {
                    return
                }

                if let error {
                    Log.debug("WebView preview height measurement failed: \(error)", category: .ui)
                    return
                }

                let height = CGFloat((result as? NSNumber)?.doubleValue ?? 0)
                self.deliverPreviewHeight(height)
            }
        }

        private func deliverPreviewHeight(_ height: CGFloat) {
            guard height > 0 else {
                return
            }

            let roundedHeight = height.rounded(.up)
            guard abs(roundedHeight - lastDeliveredPreviewHeight) > 1 else {
                return
            }

            lastDeliveredPreviewHeight = roundedHeight
            let callback = parent.onPreviewHeightChange
            DispatchQueue.main.async {
                callback?(roundedHeight)
            }
        }
    }
}
