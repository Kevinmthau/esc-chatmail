import SwiftUI
import WebKit

private final class LayoutAwareWKWebView: WKWebView {
    var onLayoutChange: ((WKWebView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutChange?(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayoutChange?(self)
    }
}

/// Configuration mode for email WebView rendering
enum EmailWebViewMode {
    /// Full interactive view with JavaScript, scrolling, and link handling
    case fullInteractive
    /// Scaled preview (e.g., 50%) with no interaction
    case scaledPreview(scale: CGFloat)
    /// Simple non-interactive preview at full size
    case simplePreview
}

/// Unified WebView for rendering email HTML content
/// Consolidates HTMLWebView, MiniEmailWebView, and HTMLPreviewWebView
struct BaseEmailWebView: UIViewRepresentable {
    let htmlContent: String
    let mode: EmailWebViewMode
    var isDarkMode: Bool? = nil
    var senderEmail: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?
    /// Optional callback for non-interactive previews that need their rendered height.
    var onPreviewHeightChange: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Register cid: scheme handler for inline attachments
        let cidHandler = CIDSchemeHandler(message: message)
        context.coordinator.cidHandler = cidHandler
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")

        switch mode {
        case .fullInteractive:
            configuration.allowsInlineMediaPlayback = true
            configuration.dataDetectorTypes = [.phoneNumber, .link, .address]
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.allowsAirPlayForMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        case .scaledPreview, .simplePreview:
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }

        let webView = LayoutAwareWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.onLayoutChange = { [weak coordinator = context.coordinator] webView in
            coordinator?.loadContentIfReady(in: webView)
        }

        switch mode {
        case .fullInteractive:
            // Match Apple Mail's WebView behavior
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = true
            // Keep full-message documents on a light trait environment so authored
            // dark-mode CSS doesn't render low-contrast text against our light surface.
            webView.overrideUserInterfaceStyle = .light
            // Use mobile user agent to trigger responsive media queries
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
            // Prevent automatic font size adjustment that can break layouts
            webView.configuration.preferences.minimumFontSize = 0
        case .scaledPreview:
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.isUserInteractionEnabled = false
        case .simplePreview:
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.isUserInteractionEnabled = false
        }

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
        var parent: BaseEmailWebView
        var lastLoadedContent: String = ""
        var lastLoadedReloadSignature: String = ""
        private var isLoading = false
        private var hasFinishedLoad = false
        private var lastDeliveredPreviewHeight: CGFloat = 0
        private var previewMeasurementGeneration = 0
        /// Holds strong reference to the cid: scheme handler
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
            case .fullInteractive, .simplePreview:
                htmlToLoad = parent.htmlContent
            }

            // Use sender domain as baseURL to provide correct Referer header for CDN images
            // (e.g., Beehiiv CDN checks Referer for hotlink protection)
            // Falls back to about:blank if no sender information available
            let baseURL = deriveBaseURL(from: parent.message, senderEmail: parent.senderEmail) ?? URL(string: "about:blank")
            webView.loadHTMLString(htmlToLoad, baseURL: baseURL)
        }

        func loadContentIfReady(in webView: WKWebView) {
            guard needsReload, !isLoading else {
                return
            }

            guard webView.window != nil,
                  webView.bounds.width > 1,
                  webView.bounds.height > 1 else {
                return
            }

            loadContent(in: webView)
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
            switch parent.mode {
            case .fullInteractive:
                webView.overrideUserInterfaceStyle = .light
            case .scaledPreview, .simplePreview:
                webView.overrideUserInterfaceStyle = .unspecified
            }
            let backgroundColor = nativeBackgroundColor(for: parent.mode) ?? .clear
            webView.backgroundColor = backgroundColor
            webView.scrollView.backgroundColor = backgroundColor
            webView.underPageBackgroundColor = backgroundColor
        }

        private func reloadSignature() -> String {
            "\(modeSignature(for: parent.mode)):\(messageIdentitySignature())"
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
            case .fullInteractive:
                return "fullInteractive:\(colorSchemeSignature)"
            case .simplePreview:
                return "simplePreview:\(colorSchemeSignature)"
            case .scaledPreview(let scale):
                // Quantize to prevent unnecessary reloads from insignificant layout jitter.
                let quantized = Int((scale * 1000.0).rounded())
                return "scaledPreview:\(quantized):\(colorSchemeSignature)"
            }
        }

        private func displayPurpose(for mode: EmailWebViewMode) -> HTMLDisplayPurpose {
            switch mode {
            case .fullInteractive:
                return .original
            case .scaledPreview, .simplePreview:
                return .preview
            }
        }

        private func nativeBackgroundColor(for mode: EmailWebViewMode) -> UIColor? {
            if case .simplePreview = mode, parent.isDarkMode == nil {
                // Preserve the old transparent simple-preview surface unless the caller opts into theming.
                return .clear
            }

            let theme = HTMLDisplayWrapper.theme(
                isDarkMode: parent.isDarkMode ?? false,
                displayPurpose: displayPurpose(for: mode)
            )
            return UIColor(hex: theme.backgroundColorHex) ?? .systemBackground
        }

        /// Derives a baseURL from the sender's email domain for proper Referer headers
        private func deriveBaseURL(from message: Message?, senderEmail: String?) -> URL? {
            EmailSenderBaseURLResolver.baseURL(from: message?.senderEmail ?? senderEmail)
        }

        private func wrapWithScale(_ html: String, scale: CGFloat) -> String {
            // Avoid nesting full HTML documents inside another <html> wrapper; that can produce blank
            // previews or render only partial/head content. Instead, inject a tiny stylesheet that scales
            // the existing document when the input already contains <html>/<doctype>.
            if html.range(of: "<!doctype", options: .caseInsensitive) != nil ||
                html.range(of: "<html", options: .caseInsensitive) != nil {
                return injectScaleStyles(into: html, scale: scale)
            }

            // Partial fragments (no document structure): wrap in our own container without adding theme CSS.
            return wrapPartialHTMLWithScale(html, scale: scale)
        }

        private func injectScaleStyles(into html: String, scale: CGFloat) -> String {
            // Scale the rendered page without touching the email's DOM structure.
            // Keep rules minimal to avoid overriding the email's own layout/CSS.
            let injected = """
            <style id="esc-preview-scale">
                html, body {
                    overflow: hidden !important;
                    min-height: 1px !important;
                }
                /* Use higher specificity + !important so template body rules don't override preview scaling. */
                html body {
                    -webkit-text-size-adjust: 100% !important;
                    transform: scale(\(scale)) !important;
                    transform-origin: top left !important;
                    width: \(100.0 / scale)% !important;
                    min-width: 0 !important;
                    min-height: 1px !important;
                    display: block !important;
                }
                img { max-width: 100%; height: auto; }
                table { max-width: 100%; }
            </style>
            """

            // Don't double-inject if the HTML already contains our scale styles.
            if html.range(of: "id=\"esc-preview-scale\"", options: .caseInsensitive) != nil {
                return ensureDoctype(html)
            }

            var result = html

            if let headRange = result.range(of: "<head>", options: .caseInsensitive) {
                result.insert(contentsOf: "\n" + injected + "\n", at: headRange.upperBound)
                return ensureDoctype(result)
            }

            if let headStart = result.range(of: "<head", options: .caseInsensitive),
               let closing = result[headStart.lowerBound...].firstIndex(of: ">") {
                let insertIndex = result.index(after: closing)
                result.insert(contentsOf: "\n" + injected + "\n", at: insertIndex)
                return ensureDoctype(result)
            }

            // No <head>: inject one immediately after the opening <html ...> tag.
            if let htmlStart = result.range(of: "<html", options: .caseInsensitive),
               let closing = result[htmlStart.lowerBound...].firstIndex(of: ">") {
                let insertIndex = result.index(after: closing)
                result.insert(contentsOf: "\n<head>\n" + injected + "\n</head>\n", at: insertIndex)
                return ensureDoctype(result)
            }

            // Worst-case fallback: wrap as a fragment.
            return wrapPartialHTMLWithScale(result, scale: scale)
        }

        private func wrapPartialHTMLWithScale(_ html: String, scale: CGFloat) -> String {
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
                <style>
                    * { box-sizing: border-box; }
                    html, body {
                        margin: 0;
                        padding: 0;
                        overflow: hidden;
                        -webkit-text-size-adjust: 100%;
                        min-height: 1px;
                    }
                    .scale-wrapper {
                        transform: scale(\(scale));
                        transform-origin: top left;
                        width: \(100.0 / scale)%;
                        min-height: 1px;
                        display: inline-block;
                    }
                    /* Only constrain, don't force widths */
                    img { max-width: 100%; height: auto; }
                    table { max-width: 100%; }
                </style>
            </head>
            <body>
                <div class="scale-wrapper">
                    \(html)
                </div>
            </body>
            </html>
            """
        }

        private func ensureDoctype(_ html: String) -> String {
            if html.range(of: "<!doctype", options: .caseInsensitive) != nil {
                return html
            }
            return "<!DOCTYPE html>\n" + html
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            switch parent.mode {
            case .fullInteractive:
                handleFullInteractiveNavigation(navigationAction, decisionHandler: decisionHandler)
            case .scaledPreview, .simplePreview:
                handlePreviewNavigation(navigationAction, decisionHandler: decisionHandler)
            }
        }

        private func handleFullInteractiveNavigation(_ navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow initial load and resource loads first (before other checks)
            // This is critical for loadHTMLString with about:blank baseURL
            if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url {
                let urlString = url.absoluteString

                // Block obviously malformed URLs
                if urlString.isEmpty || urlString == "about:blank" {
                    decisionHandler(.cancel)
                    return
                }

                // Block unsupported schemes that cause errors
                // Note: "cid" is NOT blocked - it's handled by CIDSchemeHandler
                let scheme = url.scheme?.lowercased() ?? ""
                let unsupportedSchemes = ["javascript", "vbscript", "file"]
                if unsupportedSchemes.contains(scheme) {
                    decisionHandler(.cancel)
                    return
                }
            }

            // Handle link clicks
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""

                if scheme == "x-apple-data-detectors" {
                    decisionHandler(.allow)
                    return
                }

                if (scheme == "http" || scheme == "https") &&
                    PrivateNetworkAddressDetector.isPrivateOrReserved(url) {
                    Log.warning("Blocked private/reserved email link: \(url.absoluteString)", category: .ui)
                    decisionHandler(.cancel)
                    return
                }

                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func handlePreviewNavigation(_ navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only allow initial load and reload for previews
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
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            resetLoadedSignatureAfterFailure(for: error)
            Log.debug("WebView navigation failed: \(error)", category: .ui)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            resetLoadedSignatureAfterFailure(for: error)
            Log.debug("WebView provisional navigation failed: \(error)", category: .ui)
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

            let measurementScript = """
            (function() {
                var heights = [];
                function push(value) {
                    if (typeof value === 'number' && isFinite(value) && value > 0) {
                        heights.push(value);
                    }
                }

                var wrapper = document.querySelector('.scale-wrapper');
                if (wrapper) {
                    push(wrapper.getBoundingClientRect().height);
                    push(wrapper.scrollHeight * \(scale));
                    push(wrapper.offsetHeight * \(scale));
                }

                if (document.body) {
                    push(document.body.getBoundingClientRect().height);
                    push(document.body.scrollHeight * \(scale));
                    push(document.body.offsetHeight * \(scale));
                }

                if (document.documentElement) {
                    push(document.documentElement.getBoundingClientRect().height);
                    push(document.documentElement.scrollHeight * \(scale));
                    push(document.documentElement.offsetHeight * \(scale));
                }

                return heights.length ? Math.ceil(Math.max.apply(null, heights)) : 0;
            })();
            """

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

private extension UIColor {
    convenience init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return nil
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
