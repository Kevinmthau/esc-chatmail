import SwiftUI
import UIKit
import WebKit
import CoreData

// `LayoutAwareWKWebView` lives in `FullEmailWebViewManager.swift` so the live coordinator here and
// the pre-rendered pool can share a single layout-reporting WebView type.

/// Configuration mode for email WebView rendering
enum EmailWebViewMode {
    /// Full interactive original-email view with JavaScript, scrolling, and link handling.
    ///
    /// This mode follows the original-email policy: preserve author intent by
    /// rendering in a light trait environment even when the app is in dark mode.
    case fullInteractive
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
        switch self {
        case .fullInteractive:
            return .original
        case .scaledPreview, .simplePreview:
            return .preview
        }
    }

    var webViewUserInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .fullInteractive:
            return .light
        case .scaledPreview, .simplePreview:
            return .unspecified
        }
    }
}

/// Unified WebView for rendering email HTML content.
/// Used by the full original-email view, compose previews, and the
/// MiniEmailWebView snapshot-failure fallback.
struct BaseEmailWebView: UIViewRepresentable {
    let htmlContent: String
    let mode: EmailWebViewMode
    var isDarkMode: Bool? = nil
    var senderEmail: String? = nil
    /// Optional message for resolving cid: URLs to inline attachments
    var message: Message?
    /// Optional callback for non-interactive previews that need their rendered height.
    var onPreviewHeightChange: ((CGFloat) -> Void)? = nil
    /// Optional callback invoked when a navigation finishes (first paint). The full-view reader uses
    /// this to cross-fade away its instant snapshot placeholder once the live WebView has rendered.
    var onLoadFinished: (() -> Void)? = nil
    /// Invoked when the full-view reader adopts a pre-rendered, already-painted WebView from
    /// `FullEmailWebViewManager`. The reader uses this to drop its placeholder instantly (no fade),
    /// since the content is already on screen.
    var onAdoptedPrerendered: (() -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        switch mode {
        case .fullInteractive:
            return makeFullInteractiveUIView(context: context)
        case .scaledPreview, .simplePreview:
            return makePreviewUIView(context: context)
        }
    }

    /// Full original-email path. First tries to adopt a pre-rendered, already-painted instance from
    /// `FullEmailWebViewManager` (instant open). Falls back to a fresh WebView that loads on layout.
    private func makeFullInteractiveUIView(context: Context) -> WKWebView {
        if let message,
           let checkout = FullEmailWebViewManager.shared.checkout(
               messageId: message.id,
               wrappedHTML: htmlContent,
               message: message,
               width: FullEmailWebViewMetrics.fullViewWidth()
           ) {
            return adoptPrerendered(checkout, context: context)
        }

        let cidHandler = CIDSchemeHandler(message: message)
        context.coordinator.cidHandler = cidHandler
        let configuration = FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.onLayoutChange = { [weak coordinator = context.coordinator] webView in
            coordinator?.loadContentIfReady(in: webView)
        }
        FullInteractiveEmailWebView.applySettings(to: webView)
        context.coordinator.applyBackgroundAppearance(to: webView)
        return webView
    }

    /// Adopts a warmed WebView: repoint its delegate/cid handler at the live coordinator, mark the
    /// content as already loaded so it never reloads, and tell the reader to drop its placeholder.
    private func adoptPrerendered(
        _ checkout: FullEmailWebViewManager.Checkout,
        context: Context
    ) -> WKWebView {
        let webView = checkout.webView
        context.coordinator.updateParent(self)
        context.coordinator.cidHandler = checkout.cidHandler
        checkout.cidHandler.message = message
        webView.navigationDelegate = context.coordinator
        webView.onLayoutChange = { [weak coordinator = context.coordinator] webView in
            coordinator?.loadContentIfReady(in: webView)
        }
        FullInteractiveEmailWebView.applyBackgroundAppearance(to: webView)
        context.coordinator.adoptAlreadyLoadedContent(htmlContent, messageId: message?.id)

        let onAdopted = onAdoptedPrerendered
        let onLoadFinished = onLoadFinished
        DispatchQueue.main.async {
            onAdopted?()
            onLoadFinished?()
        }
        return webView
    }

    private func makePreviewUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Register cid: scheme handler for inline attachments
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
        context.coordinator.observeAttachmentAvailabilityChanges(reloading: webView)
        context.coordinator.applyBackgroundAppearance(to: webView)
        context.coordinator.loadContentIfReady(in: webView)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.reclaimPrerenderedWebViewIfNeeded(uiView)
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
        private var attachmentAvailabilityObserver: NSObjectProtocol?
        private weak var observedContext: NSManagedObjectContext?
        private var observedMessageObjectID: NSManagedObjectID?
        private var cachedReferencedInlineCIDs: Set<String>?
        private var cachedReferencedInlineCIDsHTML: String?
        /// Holds strong reference to the cid: scheme handler
        var cidHandler: CIDSchemeHandler?
        /// Set when this coordinator adopted a pre-rendered WebView from `FullEmailWebViewManager`,
        /// so it can be reclaimed (re-hosted for instant re-open) on dismantle.
        private var adoptedPrerenderedMessageId: String?

        init(_ parent: BaseEmailWebView) {
            self.parent = parent
        }

        deinit {
            stopObservingAttachmentAvailabilityChanges()
        }

        var needsReload: Bool {
            lastLoadedContent != parent.htmlContent || lastLoadedReloadSignature != reloadSignature()
        }

        func updateParent(_ parent: BaseEmailWebView) {
            self.parent = parent
            cidHandler?.message = parent.message
        }

        func observeAttachmentAvailabilityChanges(reloading webView: WKWebView) {
            guard case .fullInteractive = parent.mode,
                  let message = parent.message,
                  let context = message.managedObjectContext else {
                stopObservingAttachmentAvailabilityChanges()
                return
            }

            let messageObjectID = message.objectID
            if let observedContext,
               observedContext === context,
               observedMessageObjectID == messageObjectID {
                return
            }

            stopObservingAttachmentAvailabilityChanges()
            observedContext = context
            observedMessageObjectID = messageObjectID
            attachmentAvailabilityObserver = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange,
                object: context,
                queue: .main
            ) { [weak self, weak webView] notification in
                guard let self, let webView else { return }
                self.reloadIfAttachmentAvailabilityChanged(notification, in: webView)
            }
        }

        private func stopObservingAttachmentAvailabilityChanges() {
            if let attachmentAvailabilityObserver {
                NotificationCenter.default.removeObserver(attachmentAvailabilityObserver)
            }
            attachmentAvailabilityObserver = nil
            observedContext = nil
            observedMessageObjectID = nil
        }

        private func reloadIfAttachmentAvailabilityChanged(_ notification: Notification, in webView: WKWebView) {
            guard notificationMayAffectCurrentMessageAttachments(notification) else {
                return
            }

            guard needsReload else {
                return
            }

            if isLoading {
                shouldReloadAfterCurrentLoad = true
                return
            }

            loadContentIfReady(in: webView)
        }

        private func notificationMayAffectCurrentMessageAttachments(_ notification: Notification) -> Bool {
            guard let messageObjectID = parent.message?.objectID else {
                return false
            }

            for object in changedObjects(in: notification) {
                if object.objectID == messageObjectID {
                    return true
                }

                guard let attachment = object as? Attachment else {
                    continue
                }

                if attachment.message?.objectID == messageObjectID {
                    return true
                }

                if parent.message?.attachments?.contains(where: { $0.objectID == attachment.objectID }) == true {
                    return true
                }
            }

            return false
        }

        private func changedObjects(in notification: Notification) -> [NSManagedObject] {
            [
                NSInsertedObjectsKey,
                NSUpdatedObjectsKey,
                NSDeletedObjectsKey,
                NSRefreshedObjectsKey,
                NSInvalidatedObjectsKey
            ].flatMap { key in
                (notification.userInfo?[key] as? Set<NSManagedObject>) ?? []
            }
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

            switch parent.mode {
            case .fullInteractive:
                return .ready
            case .scaledPreview, .simplePreview:
                guard height > 1 else {
                    return .deferred(reason: "missing-height")
                }
                return .ready
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
            lastLoadedContent = parent.htmlContent
            lastLoadedReloadSignature = reloadSignature()
            hasFinishedLoad = false
        }

        /// Marks an adopted pre-rendered WebView's content as already loaded so `needsReload` is false
        /// and no reload/first-paint occurs at display time. The instance is already painted off-screen.
        func adoptAlreadyLoadedContent(_ html: String, messageId: String?) {
            lastLoadedContent = html
            lastLoadedReloadSignature = reloadSignature()
            hasFinishedLoad = true
            isLoading = false
            adoptedPrerenderedMessageId = messageId
        }

        /// Returns an adopted pre-rendered WebView to the pool when the reader is dismantled, so a
        /// re-open stays instant. No-op for freshly-created (non-adopted) WebViews.
        func reclaimPrerenderedWebViewIfNeeded(_ webView: WKWebView) {
            guard let messageId = adoptedPrerenderedMessageId else {
                return
            }
            adoptedPrerenderedMessageId = nil
            FullEmailWebViewManager.shared.checkin(messageId: messageId, webView: webView)
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
            // Keep this in sync with the display-purpose policy: full original
            // emails use light traits, while previews stay unspecified and rely
            // on their wrapped preview theme.
            webView.overrideUserInterfaceStyle = parent.mode.webViewUserInterfaceStyle
            let backgroundColor = nativeBackgroundColor(for: parent.mode) ?? .clear
            webView.backgroundColor = backgroundColor
            webView.scrollView.backgroundColor = backgroundColor
            webView.underPageBackgroundColor = backgroundColor
        }

        private func reloadSignature() -> String {
            "\(modeSignature(for: parent.mode)):\(messageIdentitySignature()):\(inlineCIDAvailabilitySignature())"
        }

        private func messageIdentitySignature() -> String {
            guard let message = parent.message else {
                return "message:none"
            }
            return "message:\(message.id)"
        }

        private func inlineCIDAvailabilitySignature() -> String {
            guard case .fullInteractive = parent.mode else {
                return "cid:unchanged"
            }

            // `InlineCIDAttachmentAvailabilityFingerprint` scans the whole HTML for `cid:`
            // references and stats attachment files on disk, and `needsReload` evaluates
            // this on every SwiftUI update. Cache only the HTML-derived reference scan
            // (it changes solely with the HTML); attachment availability is re-evaluated
            // every call because it can change on disk without the HTML changing, and
            // `needsReload` must observe that.
            let referencedContentIDs: Set<String>
            if let cachedReferencedInlineCIDs, cachedReferencedInlineCIDsHTML == parent.htmlContent {
                referencedContentIDs = cachedReferencedInlineCIDs
            } else {
                referencedContentIDs = InlineCIDAttachmentAvailabilityFingerprint.referencedInlineContentIDs(
                    in: parent.htmlContent
                )
                cachedReferencedInlineCIDs = referencedContentIDs
                cachedReferencedInlineCIDsHTML = parent.htmlContent
            }

            return InlineCIDAttachmentAvailabilityFingerprint.fingerprint(
                referencedContentIDs: referencedContentIDs,
                message: parent.message
            )
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
                return "fullInteractive"
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
            case .fullInteractive:
                return "fullInteractive"
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

        /// Derives a baseURL from the sender's email domain for proper Referer headers
        private func deriveBaseURL(from message: Message?, senderEmail: String?) -> URL? {
            EmailSenderBaseURLResolver.baseURL(from: message?.senderEmail ?? senderEmail)
        }

        private func wrapWithScale(_ html: String, scale: CGFloat) -> String {
            HTMLPreviewScalingWrapper.wrap(html, scale: scale)
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
            // The decision logic lives in the shared, unit-tested `FullInteractiveEmailWebView`
            // `navigationDecision` so this live reader and the off-screen warm delegate stay in
            // lockstep. This wrapper only performs the WebKit-side side effects: opening external
            // links and logging blocked private/reserved ones.
            switch FullInteractiveEmailWebView.navigationDecision(
                navigationType: navigationAction.navigationType,
                url: navigationAction.request.url
            ) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .blockedPrivateNetwork(let url):
                Log.warning("Blocked private/reserved email link: \(Log.redact(url: url))", category: .ui)
                decisionHandler(.cancel)
            case .openExternally(let url):
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            }
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
            parent.onLoadFinished?()
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

enum InlineCIDAttachmentAvailabilityFingerprint {
    static func make(html: String, message: Message?) -> String {
        fingerprint(referencedContentIDs: referencedInlineContentIDs(in: html), message: message)
    }

    /// Builds the availability fingerprint for an already-extracted set of referenced
    /// `cid:` content IDs. Split out from `make` so callers can cache the (HTML-only)
    /// reference extraction while still re-evaluating live attachment availability, which
    /// can change on disk (a CID image finishing download) without the HTML changing.
    static func fingerprint(referencedContentIDs: Set<String>, message: Message?) -> String {
        guard !referencedContentIDs.isEmpty else {
            return "cid:none"
        }

        guard let message else {
            return "cid:message:none"
        }

        let attachments = message.attachmentsArray.sorted {
            sortKey(for: $0) < sortKey(for: $1)
        }

        let entries = referencedContentIDs.sorted().map { contentID in
            let matches = matchingAttachments(for: contentID, in: attachments)
            guard !matches.isEmpty else {
                return "\(contentID)=missing"
            }

            let matchSignatures = matches
                .map(availabilitySignature(for:))
                .joined(separator: ",")
            return "\(contentID)=\(matchSignatures)"
        }

        return "cid:\(entries.joined(separator: "|"))"
    }

    static func referencedInlineContentIDs(in html: String) -> Set<String> {
        EmailDocument.referencedContentIDs(in: html, terminators: EmailDocument.CIDScanTerminators.cssAndWhitespace)
    }

    private static func matchingAttachments(for contentID: String, in attachments: [Attachment]) -> [Attachment] {
        let exactMatches = attachments.filter {
            EmailDocument.normalizedContentID($0.contentId) == contentID
        }

        if !exactMatches.isEmpty {
            return exactMatches
        }

        let contentIDWithoutDomain = contentID.components(separatedBy: "@").first ?? contentID
        return attachments.filter {
            guard let attachmentContentID = EmailDocument.normalizedContentID($0.contentId) else {
                return false
            }
            let attachmentIDWithoutDomain = attachmentContentID.components(separatedBy: "@").first ?? attachmentContentID
            return attachmentIDWithoutDomain == contentIDWithoutDomain
        }
    }

    private static func availabilitySignature(for attachment: Attachment) -> String {
        let attachmentIdentity = attachment.id ?? attachment.objectID.uriRepresentation().absoluteString
        let availability: String

        if hasUsableLocalFile(attachment) {
            availability = "available:\(attachment.localURL ?? "")"
        } else if attachment.isReady {
            availability = "readyMissingLocalFile"
        } else {
            availability = "unavailable"
        }

        return "\(attachmentIdentity):\(availability)"
    }

    private static func hasUsableLocalFile(_ attachment: Attachment) -> Bool {
        guard let localURL = attachment.localURL,
              let fileURL = AttachmentPaths.fullURL(for: localURL) else {
            return false
        }

        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private static func sortKey(for attachment: Attachment) -> String {
        attachment.id ?? attachment.objectID.uriRepresentation().absoluteString
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
