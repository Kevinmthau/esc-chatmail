import SwiftUI
import UIKit
import WebKit
import CoreData

/// Dedicated WebView for displaying full original-email HTML.
///
/// Full original emails force the light rendering policy and keep interactive navigation, CID
/// attachment reloads, and guarded pre-rendered WebView adoption isolated from preview WebViews.
struct FullEmailReaderWebView: UIViewRepresentable {
    let htmlContent: String
    let sourceSignature: String?
    let message: Message?
    /// Invoked after the live WebView confirms a render pass, so the reader can drop its placeholder.
    var onLoadFinished: (() -> Void)?
    var onAdoptedPrerendered: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        if let message,
           let checkout = FullEmailWebViewManager.shared.checkout(
               messageId: message.id,
               sourceSignature: sourceSignature,
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
        FullInteractiveEmailWebView.applyBackgroundAppearance(to: webView)
        return webView
    }

    /// Adopts a warmed WebView: repoint its delegate/cid handler at the live coordinator, mark the
    /// already paint-confirmed content as loaded so it never reloads, and tell the reader to drop
    /// its placeholder.
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

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateParent(self)
        context.coordinator.observeAttachmentAvailabilityChanges(reloading: webView)
        FullInteractiveEmailWebView.applyBackgroundAppearance(to: webView)
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

        var parent: FullEmailReaderWebView
        var lastLoadedContent: String = ""
        var lastLoadedReloadSignature: String = ""
        private var isLoading = false
        private var hasFinishedLoad = false
        private var shouldReloadAfterCurrentLoad = false
        private let paintConfirmer: FullEmailReaderPaintConfirming
        private var paintConfirmationGeneration = 0
        private var attachmentAvailabilityObserver: NSObjectProtocol?
        private weak var observedContext: NSManagedObjectContext?
        private var observedMessageObjectID: NSManagedObjectID?
        private var cachedReferencedInlineCIDs: Set<String>?
        private var cachedReferencedInlineCIDsHTML: String?
        /// Holds strong reference to the cid: scheme handler.
        var cidHandler: CIDSchemeHandler?
        /// Set when this coordinator adopted a pre-rendered WebView from `FullEmailWebViewManager`,
        /// so it can be reclaimed (re-hosted for instant re-open) on dismantle.
        private var adoptedPrerenderedMessageId: String?

        init(
            _ parent: FullEmailReaderWebView,
            paintConfirmer: FullEmailReaderPaintConfirming = FullEmailReaderSnapshotPaintConfirmer()
        ) {
            self.parent = parent
            self.paintConfirmer = paintConfirmer
        }

        deinit {
            stopObservingAttachmentAvailabilityChanges()
        }

        var needsReload: Bool {
            lastLoadedContent != parent.htmlContent || lastLoadedReloadSignature != reloadSignature()
        }

        var hasAdoptedPrerenderedWebViewForTesting: Bool {
            adoptedPrerenderedMessageId != nil
        }

        func updateParent(_ parent: FullEmailReaderWebView) {
            self.parent = parent
            cidHandler?.message = parent.message
        }

        func observeAttachmentAvailabilityChanges(reloading webView: WKWebView) {
            guard let message = parent.message,
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
            recordLoadedSignature()

            let baseURL = FullInteractiveEmailWebView.baseURL(message: parent.message, senderEmail: nil)
            webView.loadHTMLString(parent.htmlContent, baseURL: baseURL)
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
                "FullEmailReaderWebView deferredLoad reason=\(reason) messageId=\(parent.message?.id ?? "nil") windowPresent=\(windowPresent) width=\(String(format: "%.1f", width)) height=\(String(format: "%.1f", height)) needsReload=\(needsReload) isLoading=\(isLoading)",
                category: .ui
            )
        }

        func recordLoadedSignature() {
            invalidatePendingPaintConfirmation()
            lastLoadedContent = parent.htmlContent
            lastLoadedReloadSignature = reloadSignature()
            hasFinishedLoad = false
        }

        /// Marks an adopted pre-rendered WebView's content as already loaded so `needsReload` is false
        /// and no live paint confirmation occurs at display time. The instance is already painted off-screen.
        func adoptAlreadyLoadedContent(_ html: String, messageId: String?) {
            invalidatePendingPaintConfirmation()
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
            invalidatePendingPaintConfirmation()
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

        private func reloadSignature() -> String {
            "fullReader:\(messageIdentitySignature()):\(sourceSignature()):\(inlineCIDAvailabilitySignature())"
        }

        private func messageIdentitySignature() -> String {
            guard let message = parent.message else {
                return "message:none"
            }
            return "message:\(message.id)"
        }

        private func sourceSignature() -> String {
            "source:\(parent.sourceSignature ?? "none")"
        }

        private func inlineCIDAvailabilitySignature() -> String {
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

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            recordFinishedLoad()
            let generation = paintConfirmationGeneration
            confirmPaint(in: webView, generation: generation) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.parent.onLoadFinished?()
                self.reloadAfterCurrentLoadIfNeeded(in: webView)
            }
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

        private func invalidatePendingPaintConfirmation() {
            paintConfirmationGeneration += 1
        }

        private func confirmPaint(
            in webView: WKWebView,
            generation: Int,
            completion: @escaping () -> Void
        ) {
            paintConfirmer.confirmPaint(in: webView) { [weak self] in
                guard let self, generation == self.paintConfirmationGeneration else {
                    return
                }
                completion()
            }
        }
    }
}

protocol FullEmailReaderPaintConfirming {
    func confirmPaint(in webView: WKWebView, completion: @escaping () -> Void)
}

struct FullEmailReaderSnapshotPaintConfirmer: FullEmailReaderPaintConfirming {
    func confirmPaint(in webView: WKWebView, completion: @escaping () -> Void) {
        let bounds = webView.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            DispatchQueue.main.async(execute: completion)
            return
        }

        webView.layoutIfNeeded()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds

        webView.takeSnapshot(with: configuration) { _, _ in
            DispatchQueue.main.async(execute: completion)
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
