import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import WebKit

// `LayoutAwareWKWebView` lives in `esc-chatmail/Platform/` so preview WebViews, the full
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

    var webViewUserInterfaceStyle: PlatformInterfaceStyle {
        .unspecified
    }
}

/// Unified preview WebView for rendering non-interactive email HTML content.
/// Used by compose previews and the MiniEmailWebView snapshot-failure fallback.
struct BaseEmailWebView: WebViewRepresentable {
    let htmlContent: String
    let mode: EmailWebViewMode
    var isDarkMode: Bool? = nil
    var senderEmail: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments.
    var message: Message?
    /// Draft-owned inline bytes, allowing compose previews without a persisted source message.
    var inlineResources: [CIDSchemeHandler.LocalResource] = []
    /// Optional callback for non-interactive previews that need their rendered height.
    var onPreviewHeightChange: ((CGFloat) -> Void)? = nil

    func makeWebView(context: Context) -> WKWebView {
        makePreviewWebView(context: context)
    }

    private func makePreviewWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The private-network rule list, when it is compiled; the coordinator attaches it before
        // its first load otherwise (`EmailWebContentNetworkRules`).
        context.coordinator.networkRules.attach(to: configuration.userContentController)

        // Register cid: scheme handler for inline attachments.
        let cidHandler = CIDSchemeHandler(message: message, localResources: inlineResources)
        context.coordinator.cidHandler = cidHandler
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = LayoutAwareWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.onLayoutChange = { [weak coordinator = context.coordinator] webView in
            coordinator?.loadContentIfReady(in: webView)
        }

        webView.makeNonInteractive()

        context.coordinator.applyBackgroundAppearance(to: webView)
        return webView
    }

    func updateWebView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateParent(self)
        context.coordinator.applyBackgroundAppearance(to: webView)
        context.coordinator.loadContentIfReady(in: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        typealias LoadReadiness = EmailWebViewLoadCoordination.LoadReadiness

        var parent: BaseEmailWebView
        /// Shared load-readiness/reload-signature core; preview WebViews
        /// require a measured height before loading.
        private let coordination = EmailWebViewLoadCoordination(requiresViewportHeight: true)
        private var isLoading = false
        private var shouldReloadAfterCurrentLoad = false
        private var lastDeliveredPreviewHeight: CGFloat = 0
        private var previewMeasurementGeneration = 0
        /// Holds strong reference to the cid: scheme handler.
        var cidHandler: CIDSchemeHandler?
        let networkRules: EmailWebContentNetworkRules
        /// A load is deferred until the private-network rule list compiles, and a callback to load
        /// then is registered once (`loadWhenNetworkRulesPermit`).
        private var isAwaitingNetworkRules = false
        /// Set once the rule list is attached to this coordinator's web view, so later updates do
        /// not ask again: `WKWebView.configuration` makes a copy on every read, and `updateWebView`
        /// runs on every SwiftUI update. A view allowed to load without the list (it could not be
        /// compiled) is not marked, so it asks again and takes the list once a retry compiles it.
        private var hasNetworkRulesAttached = false

        init(_ parent: BaseEmailWebView, networkRules: EmailWebContentNetworkRules? = nil) {
            self.parent = parent
            self.networkRules = networkRules ?? .shared
        }

        var lastLoadedContent: String {
            coordination.lastLoadedContent
        }

        var lastLoadedReloadSignature: String {
            coordination.lastLoadedReloadSignature
        }

        var needsReload: Bool {
            coordination.needsReload(content: parent.htmlContent, reloadSignature: reloadSignature())
        }

        func updateParent(_ parent: BaseEmailWebView) {
            self.parent = parent
            cidHandler?.message = parent.message
            cidHandler?.localResources = parent.inlineResources
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
            if isLoading {
                // Replay the latest input after this navigation, unless it returns to the content already loading.
                shouldReloadAfterCurrentLoad = needsReload
            }

            let windowPresent = webView.window != nil
            let width = webView.bounds.width
            let height = webView.bounds.height
            let networkRulesPermitLoading: Bool
            if hasNetworkRulesAttached {
                networkRulesPermitLoading = true
            } else {
                let controller = webView.configuration.userContentController
                networkRulesPermitLoading = networkRules.attach(to: controller)
                hasNetworkRulesAttached = networkRules.isAttached(to: controller)
            }

            switch loadReadiness(
                windowPresent: windowPresent,
                width: width,
                height: height,
                networkRulesPermitLoading: networkRulesPermitLoading
            ) {
            case .ready:
                loadContent(in: webView)
            case .deferred(let reason):
                if reason == EmailWebViewLoadCoordination.networkRulesPendingReason {
                    loadWhenNetworkRulesPermit(webView)
                }
                logDeferredLoad(
                    reason: reason,
                    windowPresent: windowPresent,
                    width: width,
                    height: height
                )
                return
            }
        }

        func loadReadiness(
            windowPresent: Bool,
            width: CGFloat,
            height: CGFloat,
            networkRulesPermitLoading: Bool
        ) -> LoadReadiness {
            coordination.loadReadiness(
                needsReload: needsReload,
                isLoading: isLoading,
                networkRulesPermitLoading: networkRulesPermitLoading,
                windowPresent: windowPresent,
                width: width,
                height: height
            )
        }

        /// Loads once the rule list has compiled. The callback holds this coordinator and the view
        /// weakly.
        private func loadWhenNetworkRulesPermit(_ webView: WKWebView) {
            guard !isAwaitingNetworkRules else { return }
            isAwaitingNetworkRules = true
            networkRules.notifyWhenLoadingPermitted { [weak self, weak webView] in
                guard let self else { return }
                self.isAwaitingNetworkRules = false
                guard let webView else { return }
                self.loadContentIfReady(in: webView)
            }
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
            coordination.recordLoadedSignature(
                content: parent.htmlContent,
                reloadSignature: reloadSignature()
            )
        }

        func recordFinishedLoad() {
            coordination.recordFinishedLoad()
        }

        func resetLoadedSignatureAfterFailure() {
            coordination.resetLoadedSignatureAfterFailure()
        }

        func resetLoadedSignatureAfterFailure(for error: Error) {
            coordination.resetLoadedSignatureAfterFailure(for: error)
        }

        func applyBackgroundAppearance(to webView: WKWebView) {
            webView.applyInterfaceStyle(parent.mode.webViewUserInterfaceStyle)
            webView.applyNativeBackgroundColor(nativeBackgroundColor(for: parent.mode) ?? .clear)
        }

        private func reloadSignature() -> String {
            let resources = parent.inlineResources.map { "\($0.contentID):\($0.localURL):\($0.mimeType)" }.joined(separator: "|")
            return "\(modeSignature(for: parent.mode)):\(messageIdentitySignature()):source:none:cid:\(resources)"
        }

        private func messageIdentitySignature() -> String {
            EmailWebViewLoadCoordination.messageIdentitySignature(messageId: parent.message?.id)
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

        private func nativeBackgroundColor(for mode: EmailWebViewMode) -> PlatformColor? {
            if case .simplePreview = mode, parent.isDarkMode == nil {
                // Preserve the old transparent simple-preview surface unless the caller opts into theming.
                return .clear
            }

            let theme = HTMLDisplayWrapper.theme(
                isDarkMode: parent.isDarkMode ?? false,
                displayPurpose: mode.displayPurpose
            )
            return PlatformColor(hex: theme.backgroundColorHex) ?? .systemBackground
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
            // Only allow initial load and reload for previews, and neither to a private host other
            // than the preview's own base host (a meta refresh: `EmailDocumentNavigationGuard`).
            let isOwnLoad = navigationAction.navigationType == .other || navigationAction.navigationType == .reload
            if isOwnLoad, !EmailDocumentNavigationGuard.refusesAutomaticNavigation(
                to: navigationAction.request.url,
                documentBaseURL: deriveBaseURL(from: parent.message, senderEmail: parent.senderEmail)
            ) {
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
            guard !EmailWebViewLoadCoordination.isWebContentProcessTerminationError(error) else { return }
            isLoading = false
            resetLoadedSignatureAfterFailure(for: error)
            Log.debug("WebView navigation failed: \(error)", category: .ui)
            reloadAfterCurrentLoadIfNeeded(in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !EmailWebViewLoadCoordination.isWebContentProcessTerminationError(error) else { return }
            isLoading = false
            resetLoadedSignatureAfterFailure(for: error)
            Log.debug("WebView provisional navigation failed: \(error)", category: .ui)
            reloadAfterCurrentLoadIfNeeded(in: webView)
        }

        /// The preview's WebContent process died, so the preview shows nothing. Implementing this
        /// also stops WebKit's own reload, which loads a pending load's base URL from the network
        /// (see `FullEmailReaderWebView.Coordinator.webViewWebContentProcessDidTerminate`). The
        /// preview reloads the content it holds, never the base URL, as often as
        /// `admitsReloadAfterWebContentTermination` allows (at most three times for one content
        /// and signature), so a page that crashes WebKit is not reloaded for as long as it is on
        /// screen.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Log.warning(
                "Preview WebContent process terminated messageId=\(Log.hashIdentifier(parent.message?.id))",
                category: .ui
            )
            isLoading = false
            shouldReloadAfterCurrentLoad = false
            previewMeasurementGeneration &+= 1
            guard coordination.admitsReloadAfterWebContentTermination(
                content: parent.htmlContent,
                reloadSignature: reloadSignature()
            ) else {
                return
            }
            resetLoadedSignatureAfterFailure()
            loadContentIfReady(in: webView)
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
