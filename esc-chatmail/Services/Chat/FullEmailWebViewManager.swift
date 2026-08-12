import Foundation
import UIKit
import WebKit

// MARK: - Reusable layout-aware WKWebView

/// A `WKWebView` subclass that reports layout/window changes so email WebView coordinators can
/// (re)load content once they have a window and valid dimensions.
///
/// Shared by preview WebViews, the full reader, and the pre-rendered `FullEmailWebViewManager` so a
/// warmed full-reader instance can be adopted without losing its layout callbacks.
final class LayoutAwareWKWebView: WKWebView {
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

// MARK: - Shared full-interactive configuration / navigation policy

/// Configuration, settings, and navigation policy for the full original-email WebView.
///
/// Factored out so the live `FullEmailReaderWebView` and the pre-rendered `FullEmailWebViewManager`
/// produce byte-identical renders. If they diverged, a pre-rendered instance would re-layout (and
/// flash) the moment it was adopted into the full-view reader, defeating the point of warming.
enum FullInteractiveEmailWebView {
    /// Builds the `WKWebViewConfiguration` for full original-email rendering.
    static func makeConfiguration(cidHandler: CIDSchemeHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Register cid: scheme handler for inline attachments.
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")
        configuration.allowsInlineMediaPlayback = false
        configuration.dataDetectorTypes = [.phoneNumber, .link, .address]
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    /// Applies full-interactive WebView settings: scroll insets, forced-light trait (preserve authored
    /// colors), mobile user agent (trigger responsive media queries), and no minimum font size.
    static func applySettings(to webView: WKWebView) {
        // Match Apple Mail's WebView behavior.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = true
        // Full original emails force a light trait environment to preserve the author's intended
        // presentation instead of opting the document into app dark mode.
        webView.overrideUserInterfaceStyle = .light
        // Use mobile user agent to trigger responsive media queries.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        // Prevent automatic font size adjustment that can break layouts.
        webView.configuration.preferences.minimumFontSize = 0
    }

    /// Applies the opaque/background appearance for the forced-light original-email surface.
    static func applyBackgroundAppearance(to webView: WKWebView) {
        webView.isOpaque = false
        webView.overrideUserInterfaceStyle = .light
        let theme = HTMLDisplayWrapper.theme(isDarkMode: false, displayPurpose: .original)
        let backgroundColor = UIColor(hex: theme.backgroundColorHex) ?? .systemBackground
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        webView.underPageBackgroundColor = backgroundColor
    }

    /// Sender-domain base URL so CDN images relying on Referer (e.g. Beehiiv hotlink protection) load.
    static func baseURL(message: Message?, senderEmail: String?) -> URL {
        EmailSenderBaseURLResolver.baseURL(from: message?.senderEmail ?? senderEmail)
            ?? URL(string: "about:blank")!
    }

    // MARK: Navigation policy (pure, shared, unit-testable)

    enum NavigationDecision: Equatable {
        /// Permit the navigation (initial/resource loads, reloads, data-detector taps, form posts).
        case allow
        /// Cancel without side effects (malformed/about:blank URLs, unsupported schemes).
        case cancel
        /// Cancel a link to a private/reserved host. Carries the URL so the caller can log the block;
        /// the decision stays pure (no logging here) and the side effect lives with the caller.
        case blockedPrivateNetwork(URL)
        /// Cancel in-WebView and hand the link to the system browser instead.
        case openExternally(URL)
    }

    private enum ExternalLinkResolution {
        case open(URL)
        case cancel
    }

    private enum AmazonSESTrackingDestination {
        case notTrackingURL
        case destination(URL)
        case blockedDestination
    }

    private static let unsupportedNavigationSchemes = ["javascript", "vbscript", "file"]
    private static let allowedUnwrappedAmazonSESDestinationSchemes = ["http", "https", "mailto", "tel"]

    /// Pure navigation decision for the full-interactive WebView, shared by the live `Coordinator`
    /// (which performs the side effects — opening external URLs, logging blocked links) and the
    /// off-screen `WarmNavigationDelegate` (which has no side effects — it permits the `.allow` cases
    /// and cancels the link-opening and blocked-link cases). Keeping the decision pure lets it be
    /// unit-tested without WebKit.
    static func navigationDecision(
        navigationType: WKNavigationType,
        url: URL?
    ) -> NavigationDecision {
        // Screen dangerous/unsupported schemes first, for every navigation type, so a
        // javascript:/vbscript:/file: URL can never load — not even disguised as an .other or
        // .reload navigation (e.g. a scripted location change). The document's own initial
        // `loadHTMLString` navigation arrives as .other with an about:/base-URL scheme, which is not
        // screened here, so the initial load still proceeds. Note: "cid" is NOT blocked — it is
        // handled by CIDSchemeHandler.
        if let url {
            if isUnsupportedNavigationURL(url) {
                return .cancel
            }
        }

        // Full original emails are read-only: never submit (or resubmit) a form from email content.
        if navigationType == .formSubmitted || navigationType == .formResubmitted {
            return .cancel
        }

        // Allow the initial document load, resource loads, and reloads. This is critical for
        // loadHTMLString with an about:blank/base-URL baseURL, which arrives as .other.
        if navigationType == .other || navigationType == .reload {
            return .allow
        }

        if let url {
            let urlString = url.absoluteString
            // Block obviously malformed URLs.
            if urlString.isEmpty || urlString == "about:blank" {
                return .cancel
            }
        }

        // Handle link clicks.
        if navigationType == .linkActivated, let url {
            let externalURL: URL
            switch externalLinkResolution(for: url) {
            case .open(let resolvedURL):
                externalURL = resolvedURL
            case .cancel:
                return .cancel
            }
            let scheme = externalURL.scheme?.lowercased() ?? ""
            if scheme == "x-apple-data-detectors" {
                return .allow
            }
            if isUnsupportedNavigationURL(externalURL) {
                return .cancel
            }
            if scheme == "http" || scheme == "https",
               PrivateNetworkAddressDetector.isPrivateOrReserved(externalURL) {
                return .blockedPrivateNetwork(externalURL)
            }
            return .openExternally(externalURL)
        }

        return .allow
    }

    private static func isUnsupportedNavigationURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return unsupportedNavigationSchemes.contains(scheme)
    }

    private static func externalLinkResolution(for url: URL) -> ExternalLinkResolution {
        switch amazonSESTrackingDestination(from: url) {
        case .notTrackingURL:
            return .open(url)
        case .destination(let destination):
            return .open(destination)
        case .blockedDestination:
            return .cancel
        }
    }

    private static func amazonSESTrackingDestination(from url: URL) -> AmazonSESTrackingDestination {
        guard isAmazonSESTrackingHost(url.host),
              let trackingMarkerIndex = url.pathComponents.firstIndex(of: "L0") else {
            return .notTrackingURL
        }

        let destinationIndex = url.pathComponents.index(after: trackingMarkerIndex)
        guard destinationIndex < url.pathComponents.endIndex else {
            return .blockedDestination
        }

        guard let destination = URL(string: url.pathComponents[destinationIndex]) else {
            return .blockedDestination
        }

        guard isAllowedUnwrappedAmazonSESDestination(destination) else {
            return .blockedDestination
        }

        return .destination(destination)
    }

    private static func isAllowedUnwrappedAmazonSESDestination(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return allowedUnwrappedAmazonSESDestinationSchemes.contains(scheme)
    }

    private static func isAmazonSESTrackingHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }

        return host == "awstrack.me" || host.hasSuffix(".awstrack.me")
    }
}

enum EmailReaderRenderingConfiguration {
    static var enablesPreparedHTMLWarmup: Bool {
        true
    }

    static var enablesOffscreenWebViewAdoption: Bool {
        FullEmailWebViewAdoptionPolicy.allowsPrerenderedWebViewAdoption
    }

    static func visibleRowWarmWidthEstimate(sceneScreenWidth: CGFloat?) -> CGFloat? {
        guard enablesOffscreenWebViewAdoption,
              let sceneScreenWidth,
              sceneScreenWidth > 1 else {
            return nil
        }
        return sceneScreenWidth
    }

    @MainActor
    static func currentVisibleRowWarmWidthEstimate() -> CGFloat? {
        visibleRowWarmWidthEstimate(
            sceneScreenWidth: FullEmailWebViewMetrics.activeWindowScene()?.screen.bounds.width
        )
    }
}

// MARK: - Metrics

enum FullEmailWebViewMetrics {
    @MainActor
    static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - Pre-render key

/// Identifies a pre-rendered full-email WebView. A checkout only succeeds when the reader's content
/// matches the warmed content exactly — same source signature, same wrapped HTML, same
/// inline-attachment availability, and same render width — so an adopted instance never has to
/// re-layout.
struct FullEmailWebViewPreRenderKey: Hashable, Sendable {
    let messageId: String
    let sourceSignature: String
    let htmlFingerprint: String
    let cidAvailabilityFingerprint: String
    let widthBucket: Int

    static func make(
        messageId: String,
        sourceSignature: String,
        wrappedHTML: String,
        cidAvailabilityFingerprint: String,
        width: CGFloat
    ) -> FullEmailWebViewPreRenderKey {
        FullEmailWebViewPreRenderKey(
            messageId: messageId,
            sourceSignature: sourceSignature,
            htmlFingerprint: fingerprint(for: wrappedHTML),
            cidAvailabilityFingerprint: cidAvailabilityFingerprint,
            widthBucket: Int(width.rounded())
        )
    }

    private static func fingerprint(for text: String) -> String {
        "\(text.utf8.count):\(StableFingerprint.sha256Prefix(text))"
    }
}

struct FullEmailPreparedArtifactKey: Hashable, Sendable {
    let messageId: String
    let sourceSignature: String
    let htmlFingerprint: String

    static func make(
        messageId: String,
        sourceSignature: String,
        wrappedHTML: String
    ) -> FullEmailPreparedArtifactKey {
        FullEmailPreparedArtifactKey(
            messageId: messageId,
            sourceSignature: sourceSignature,
            htmlFingerprint: "\(wrappedHTML.utf8.count):\(StableFingerprint.sha256Prefix(wrappedHTML))"
        )
    }
}

// MARK: - Full-email open payload

struct FullEmailOpenPayload: Equatable, Sendable {
    enum CheckoutAvailability: String, Sendable {
        case ready
        case warming
    }

    let messageId: String
    let sourceSignature: String
    let html: String
    let presentation: OriginalEmailSource.Presentation
    let sourceKind: CanonicalEmailSourceKind
    let sourceLocation: CanonicalEmailSourceLocation
    let hasHTMLSource: Bool
    let checkoutAvailability: CheckoutAvailability

    init(
        messageId: String,
        sourceSignature: String,
        html: String,
        presentation: OriginalEmailSource.Presentation,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        hasHTMLSource: Bool,
        checkoutAvailability: CheckoutAvailability
    ) {
        self.messageId = messageId
        self.sourceSignature = sourceSignature
        self.html = html
        self.presentation = presentation
        self.sourceKind = sourceKind
        self.sourceLocation = sourceLocation
        self.hasHTMLSource = hasHTMLSource
        self.checkoutAvailability = checkoutAvailability
    }

    var originalEmailSource: OriginalEmailSource {
        OriginalEmailSource(
            presentation: presentation,
            html: presentation == .html ? html : nil,
            plainText: nil,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            sourceSignature: sourceSignature,
            hasHTMLSource: hasHTMLSource
        )
    }

    func withCheckoutAvailability(_ checkoutAvailability: CheckoutAvailability) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: messageId,
            sourceSignature: sourceSignature,
            html: html,
            presentation: presentation,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            hasHTMLSource: hasHTMLSource,
            checkoutAvailability: checkoutAvailability
        )
    }

    init(
        artifact: EmailReaderArtifact,
        checkoutAvailability: CheckoutAvailability
    ) {
        self.messageId = artifact.messageID
        self.sourceSignature = artifact.sourceSignature
        switch artifact.body {
        case .html(let html):
            self.html = html
        case .plainText:
            self.html = ""
        }
        self.presentation = .html
        self.sourceKind = artifact.sourceKind
        self.sourceLocation = artifact.sourceLocation
        self.hasHTMLSource = artifact.hasHTMLSource
        self.checkoutAvailability = checkoutAvailability
    }

    func artifact(
        metadata: EmailMetadataSnapshot,
        message: Message?,
        producedAt: Date = Date()
    ) -> EmailReaderArtifact {
        EmailReaderArtifact(
            messageID: messageId,
            sourceSignature: sourceSignature,
            body: .html(html),
            metadata: metadata,
            inlineAttachmentAvailabilitySignature: InlineCIDAttachmentAvailabilityFingerprint.make(
                html: html,
                message: message
            ),
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            hasHTMLSource: hasHTMLSource,
            producedAt: producedAt
        )
    }
}

enum FullEmailOpenPayloadReuseDecision: Equatable {
    case reusable
    case missingCurrentHTMLSource
    case staleSource(currentSourceSignature: String)
    case wrapperInputsMismatch
    case keyMismatch
}

enum FullEmailWebViewAdoptionPolicy {
    // Legacy opt-in flags. Adoption is now on by default, so these are retained only as no-ops for
    // backward compatibility; nothing reads them.
    static let enableLaunchArgument = "-ESCEnableFullEmailWebViewAdoption"
    static let enableEnvironmentKey = "ESC_ENABLE_FULL_EMAIL_WEBVIEW_ADOPTION"
    static let disableLaunchArgument = "-ESCDisableFullEmailWebViewAdoption"
    static let disableEnvironmentKey = "ESC_DISABLE_FULL_EMAIL_WEBVIEW_ADOPTION"

    // Backward-compatible aliases for the now-no-op enable flags.
    static let launchArgument = enableLaunchArgument
    static let environmentKey = enableEnvironmentKey

    static var allowsPrerenderedWebViewAdoption: Bool {
        isEnabled(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static var explicitlyDisablesPrerenderedWebViewAdoption: Bool {
        isExplicitlyDisabled(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func isEnabled(arguments: [String], environment: [String: String]) -> Bool {
        // Adoption is on by default; only the explicit kill switch
        // (`-ESCDisableFullEmailWebViewAdoption` / `ESC_DISABLE_FULL_EMAIL_WEBVIEW_ADOPTION=1`)
        // disables it. The legacy enable flags (`enableLaunchArgument` / `enableEnvironmentKey`) are
        // retained as no-ops for backward compatibility.
        !isExplicitlyDisabled(arguments: arguments, environment: environment)
    }

    static func isExplicitlyDisabled(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains(disableLaunchArgument) || isEnabledEnvironmentValue(environment[disableEnvironmentKey])
    }

    private static func isEnabledEnvironmentValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value == "1"
    }
}

private struct OriginalEmailWarmWrapperInputs: Equatable {
    let bodyTextFingerprint: String
    let senderEmail: String?
    let subject: String?

    init(request: OriginalEmailWarmRequest) {
        self.bodyTextFingerprint = Self.canonicalBodyTextFingerprint(for: request.bodyText)
        self.senderEmail = Self.normalized(request.senderEmail)
        self.subject = Self.normalized(request.subject)
    }

    private static func canonicalBodyTextFingerprint(for text: String?) -> String {
        guard let normalizedText = CanonicalEmailContentLoader.normalizedMeaningfulPlainText(from: text) else {
            return "nil"
        }

        return fingerprint(for: normalizedText)
    }

    private static func fingerprint(for text: String) -> String {
        StableFingerprint.sha256Prefix(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}

enum FullEmailOpenPayloadReuseValidator {
    static func decision(
        entryKey: FullEmailPreparedArtifactKey,
        expectedKey: FullEmailPreparedArtifactKey,
        entryRequest: OriginalEmailWarmRequest,
        currentRequest: OriginalEmailWarmRequest,
        payload: FullEmailOpenPayload,
        currentSourceSignature: String?
    ) -> FullEmailOpenPayloadReuseDecision {
        if let currentSourceSignature {
            if currentSourceSignature != payload.sourceSignature {
                return .staleSource(currentSourceSignature: currentSourceSignature)
            }
        } else if payload.presentation == .html {
            return .missingCurrentHTMLSource
        }

        let entryWrapperInputs = OriginalEmailWarmWrapperInputs(request: entryRequest)
        let currentWrapperInputs = OriginalEmailWarmWrapperInputs(request: currentRequest)
        guard entryWrapperInputs == currentWrapperInputs else {
            return .wrapperInputsMismatch
        }

        guard entryKey == expectedKey else {
            return .keyMismatch
        }

        return .reusable
    }
}

struct FullEmailAccountWorkGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
}

@MainActor
protocol FullEmailOpening: AnyObject {
    func captureAccountWorkGeneration() -> FullEmailAccountWorkGeneration?

    func registerOpenSession(_ session: FullEmailOpenSession)

    func preparedOpenArtifact(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat?
    ) -> EmailReaderPreparedArtifact?

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat
    )

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat,
        expectedAccountGeneration: FullEmailAccountWorkGeneration?
    )

    func warm(request: OriginalEmailWarmRequest, message: Message?, width: CGFloat?) async

    func prewarmOnOpen(message: Message, width: CGFloat?)
}

extension FullEmailOpening {
    func captureAccountWorkGeneration() -> FullEmailAccountWorkGeneration? { nil }

    func registerOpenSession(_ session: FullEmailOpenSession) {}

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat
    ) {}

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat,
        expectedAccountGeneration: FullEmailAccountWorkGeneration?
    ) {
        prepaintAfterExplicitOpen(
            request: request,
            message: message,
            artifact: artifact,
            width: width
        )
    }

    func prewarmOnOpen(message: Message, width: CGFloat?) {}

    func warm(request: OriginalEmailWarmRequest, message: Message?, width: CGFloat?) async {}
}

@MainActor
protocol FullEmailWebViewAdopting: AnyObject {
    func checkout(
        messageId: String,
        sourceSignature: String?,
        wrappedHTML: String,
        message: Message?,
        width: CGFloat
    ) -> FullEmailWebViewManager.Checkout?

    @discardableResult
    func checkin(messageId: String, webView: WKWebView) -> Bool
}

// MARK: - Live full-reader account boundary

/// Tracks the on-screen full-reader WebViews that are not necessarily owned by the pre-render pool.
/// Records are weak so normal SwiftUI lifetime remains authoritative; account cleanup uses the
/// registry only to synchronously scrub every still-live reader and then boundedly verify that its
/// old document has been replaced.
@MainActor
final class FullEmailReaderAccountBoundaryRegistry {
    static let shared = FullEmailReaderAccountBoundaryRegistry()

    typealias BlankDocumentAwaiter = @MainActor ([LayoutAwareWKWebView]) async -> Void

    private final class Record {
        weak var webView: LayoutAwareWKWebView?
        weak var coordinator: FullEmailReaderWebView.Coordinator?

        init(webView: LayoutAwareWKWebView, coordinator: FullEmailReaderWebView.Coordinator) {
            self.webView = webView
            self.coordinator = coordinator
        }
    }

    private let blankDocumentAwaiter: BlankDocumentAwaiter
    private var records: [ObjectIdentifier: Record] = [:]
    /// Admission flag only — deliberately short of the full account-generation
    /// participant contract: register() is synchronous MainActor work with no
    /// suspension between the admission check and the write, so there is no
    /// window a generation token would close. A reader scrubbed at
    /// registration is permanently dead, not blank-until-reopen: its
    /// Coordinator latches isInvalidated and SwiftUI reuses it after reopen.
    /// Not reachable through today's UI — a closed pool invalidates every
    /// FullEmailOpenSession at init, so no FullEmailReaderWebView is
    /// constructed while the registry is closed; the guard is defense in
    /// depth for a future consumer of FullEmailReaderWebView that is not
    /// gated by an open session.
    private var acceptsAccountWork = true

    init(blankDocumentAwaiter: BlankDocumentAwaiter? = nil) {
        self.blankDocumentAwaiter = blankDocumentAwaiter ?? { webViews in
            await FullEmailReaderAccountBoundaryRegistry.awaitBlankDocuments(in: webViews)
        }
    }

    func register(
        webView: LayoutAwareWKWebView,
        coordinator: FullEmailReaderWebView.Coordinator
    ) {
        guard acceptsAccountWork else {
            coordinator.scrubForAccountBoundary(webView)
            return
        }
        purgeReleasedRecords()
        records[ObjectIdentifier(webView)] = Record(webView: webView, coordinator: coordinator)
    }

    func unregister(webView: WKWebView) {
        records.removeValue(forKey: ObjectIdentifier(webView))
    }

    func clearForAccountTransition(
        additionallyAwaiting additionalWebViews: [LayoutAwareWKWebView] = []
    ) async {
        acceptsAccountWork = false
        let liveRecords = Array(records.values)
        records.removeAll(keepingCapacity: false)

        var webViewsByID = Dictionary(
            uniqueKeysWithValues: additionalWebViews.map { (ObjectIdentifier($0), $0) }
        )
        for record in liveRecords {
            guard let webView = record.webView else { continue }
            webViewsByID[ObjectIdentifier(webView)] = webView
            if let coordinator = record.coordinator {
                coordinator.scrubForAccountBoundary(webView)
            } else {
                Self.scrubUncoordinated(webView)
            }
        }

        await blankDocumentAwaiter(Array(webViewsByID.values))
    }

    func reopenAccountWork() {
        acceptsAccountWork = true
    }

    private func purgeReleasedRecords() {
        records = records.filter { $0.value.webView != nil }
    }

    private static func scrubUncoordinated(_ webView: LayoutAwareWKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.onLayoutChange = nil
        webView.loadHTMLString("", baseURL: URL(string: "about:blank"))
    }

    /// `WKWebView.loadHTMLString` is asynchronous. Account cleanup does not wait indefinitely for a
    /// damaged WebKit process, but it does yield long enough for healthy readers to replace their DOM.
    private static func awaitBlankDocuments(in webViews: [LayoutAwareWKWebView]) async {
        let awaiter = FullEmailBlankDocumentAwaiter(webViews: webViews) { webView, completion in
            webView.evaluateJavaScript("document.body ? document.body.innerHTML : ''") { value, _ in
                completion(value as? String)
            }
        }
        await awaiter.wait()
    }
}

/// Bounded callback coordinator for the account-boundary DOM verification pass.
///
/// WebKit's async `evaluateJavaScript` bridge cannot provide a hard deadline when its completion
/// handler never arrives. This coordinator uses the callback API directly, probes all readers in
/// parallel, and owns the single deadline for the whole pass. Late callbacks hold only a weak
/// reference and are ignored after settlement, so they cannot retain the waiter or restart polling.
@MainActor
final class FullEmailBlankDocumentAwaiter {
    typealias Evaluator = (LayoutAwareWKWebView, @escaping (String?) -> Void) -> Void

    private let evaluator: Evaluator
    private let timeoutNanoseconds: UInt64
    private let retryNanoseconds: UInt64
    private var pendingByID: [ObjectIdentifier: LayoutAwareWKWebView] = [:]
    private var outstandingIDs: Set<ObjectIdentifier> = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isFinished = false

    init(
        webViews: [LayoutAwareWKWebView],
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        retryNanoseconds: UInt64 = 10_000_000,
        evaluator: @escaping Evaluator
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryNanoseconds = retryNanoseconds
        self.evaluator = evaluator
        for webView in webViews {
            pendingByID[ObjectIdentifier(webView)] = webView
        }
    }

    func wait() async {
        guard !pendingByID.isEmpty, !isFinished else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Never>) {
        guard !isFinished else {
            continuation.resume()
            return
        }

        precondition(self.continuation == nil, "A blank-document waiter may only be awaited once")
        self.continuation = continuation
        guard !Task.isCancelled else {
            finish()
            return
        }

        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            finish()
        }
        probePendingDocuments()
    }

    private func probePendingDocuments() {
        guard !isFinished, outstandingIDs.isEmpty else { return }
        guard !pendingByID.isEmpty else {
            finish()
            return
        }

        let pending = Array(pendingByID)
        outstandingIDs = Set(pending.map(\.key))
        for (id, webView) in pending {
            evaluator(webView) { [weak self] bodyHTML in
                Task { @MainActor [weak self] in
                    self?.didEvaluateDocument(id: id, bodyHTML: bodyHTML)
                }
            }
        }
    }

    private func didEvaluateDocument(id: ObjectIdentifier, bodyHTML: String?) {
        guard !isFinished, outstandingIDs.remove(id) != nil else { return }
        if bodyHTML?.isEmpty == true {
            pendingByID.removeValue(forKey: id)
        }

        guard outstandingIDs.isEmpty else { return }
        guard !pendingByID.isEmpty else {
            finish()
            return
        }

        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: retryNanoseconds)
            } catch {
                return
            }
            retryTask = nil
            probePendingDocuments()
        }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        retryTask?.cancel()
        timeoutTask = nil
        retryTask = nil
        pendingByID.removeAll(keepingCapacity: false)
        outstandingIDs.removeAll(keepingCapacity: false)

        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

// MARK: - Pure LRU bookkeeping

/// WebKit-free LRU bookkeeping for the pre-rendered pool, so eviction order can be unit-tested
/// without instantiating real `WKWebView`s. Tracks message IDs most-recently-used last.
struct FullEmailWebViewPoolBookkeeping: Equatable {
    let capacity: Int
    private(set) var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Records access for a message ID (warm or checkout) and returns any message IDs that overflow
    /// the capacity and must be evicted.
    mutating func touch(_ messageId: String) -> [String] {
        order.removeAll { $0 == messageId }
        order.append(messageId)

        var evicted: [String] = []
        while order.count > capacity {
            evicted.append(order.removeFirst())
        }
        return evicted
    }

    mutating func remove(_ messageId: String) {
        order.removeAll { $0 == messageId }
    }

    mutating func removeAll() {
        order.removeAll()
    }
}

struct FullEmailRemoteImageFallbackBookkeeping: Equatable {
    struct WarmContext: Equatable {
        let request: OriginalEmailWarmRequest
        let width: CGFloat?
    }

    private var generations: [String: Int] = [:]
    private var warmContexts: [String: WarmContext] = [:]

    func generation(for messageId: String) -> Int {
        generations[messageId] ?? 0
    }

    func isCurrent(messageId: String, generation: Int) -> Bool {
        self.generation(for: messageId) == generation
    }

    mutating func markFallbackWarmed(messageId: String) {
        generations[messageId, default: 0] &+= 1
    }

    mutating func rememberWarmContext(request: OriginalEmailWarmRequest, width: CGFloat?) {
        warmContexts[request.messageId] = WarmContext(request: request, width: width)
    }

    func warmContext(for messageId: String) -> WarmContext? {
        warmContexts[messageId]
    }

    mutating func removeWarmContext(messageId: String) {
        warmContexts.removeValue(forKey: messageId)
    }

    mutating func removeAllWarmContexts() {
        warmContexts.removeAll()
    }
}

struct FullEmailPreparedOpenPayloadBookkeeping: Equatable {
    struct Entry: Equatable {
        let key: FullEmailPreparedArtifactKey
        var request: OriginalEmailWarmRequest
        var payload: FullEmailOpenPayload
    }

    private var entries: [String: Entry] = [:]

    mutating func store(
        key: FullEmailPreparedArtifactKey,
        request: OriginalEmailWarmRequest,
        payload: FullEmailOpenPayload
    ) {
        entries[request.messageId] = Entry(
            key: key,
            request: request,
            payload: payload
        )
    }

    func entry(for messageId: String) -> Entry? {
        entries[messageId]
    }

    mutating func remove(_ messageId: String) {
        entries.removeValue(forKey: messageId)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    var messageIds: Set<String> {
        Set(entries.keys)
    }
}

// MARK: - Manager

/// Prepares full original-email HTML while chat bubbles are visible (and when a bubble is tapped),
/// then hands that HTML to the reader so the open can skip cold sanitization/wrapping.
///
/// Prepared HTML warming is the default safe path. Active off-screen `WKWebView` adoption remains
/// opt-in for scroll-time visible-row warming through `FullEmailWebViewAdoptionPolicy`. A separate
/// explicit-open path can start or promote a matching WebView after the user opens the full original
/// email, making later opens eligible for checkout.
@MainActor
final class FullEmailWebViewManager: FullEmailOpening, FullEmailWebViewAdopting {
    static let shared = FullEmailWebViewManager()

    struct Checkout {
        let webView: LayoutAwareWKWebView
        let cidHandler: CIDSchemeHandler
    }

    private final class Entry {
        enum PrepaintSource {
            case visibleRowWarm
            case explicitOpen
        }

        let key: FullEmailWebViewPreRenderKey
        var request: OriginalEmailWarmRequest
        var payload: FullEmailOpenPayload
        var prepaintSource: PrepaintSource
        let webView: LayoutAwareWKWebView
        let cidHandler: CIDSchemeHandler
        let delegate: WarmNavigationDelegate
        var didFinishInitialLoad = false
        /// True while the instance is displayed in the reader. It stays tracked so checkin can find
        /// it, but warming and checkout skip it.
        var isCheckedOut = false

        init(
            key: FullEmailWebViewPreRenderKey,
            request: OriginalEmailWarmRequest,
            payload: FullEmailOpenPayload,
            prepaintSource: PrepaintSource,
            webView: LayoutAwareWKWebView,
            cidHandler: CIDSchemeHandler,
            delegate: WarmNavigationDelegate
        ) {
            self.key = key
            self.request = request
            self.payload = payload
            self.prepaintSource = prepaintSource
            self.webView = webView
            self.cidHandler = cidHandler
            self.delegate = delegate
        }
    }

    private let capacity: Int
    private let loader: OriginalEmailSourceLoader
    private let host = OffscreenWebViewHost()
    private var entries: [String: Entry] = [:]
    private var preparedPayloads = FullEmailPreparedOpenPayloadBookkeeping()
    private var bookkeeping: FullEmailWebViewPoolBookkeeping
    private var remoteImageFallbackBookkeeping = FullEmailRemoteImageFallbackBookkeeping()
    private var remoteImageFallbackMessages: [String: Message] = [:]
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private var activeWarmOperations: Set<UUID> = []
    private var warmDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var prewarmTasks: [UUID: Task<Void, Never>] = [:]
    private var openSessions: [ObjectIdentifier: WeakOpenSession] = [:]

    private final class WeakOpenSession {
        weak var value: FullEmailOpenSession?

        init(_ value: FullEmailOpenSession) {
            self.value = value
        }
    }

    init(capacity: Int = 4, loader: OriginalEmailSourceLoader = .shared) {
        self.capacity = max(1, capacity)
        self.loader = loader
        self.bookkeeping = FullEmailWebViewPoolBookkeeping(capacity: capacity)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clear()
            }
        }

        NotificationCenter.default.addObserver(
            forName: HTMLContentLoader.remoteImageAttachmentFallbackDidWarmNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let messageId = notification.userInfo?[HTMLContentLoader.remoteImageAttachmentFallbackMessageIdUserInfoKey] as? String else {
                return
            }
            Task { @MainActor in
                await self?.handleRemoteImageFallbackDidWarm(messageId: messageId)
            }
        }
    }

    // MARK: Warming

    func captureAccountWorkGeneration() -> FullEmailAccountWorkGeneration? {
        guard acceptsAccountWork else { return nil }
        return FullEmailAccountWorkGeneration(value: accountGeneration)
    }

    func registerOpenSession(_ session: FullEmailOpenSession) {
        openSessions = openSessions.filter { $0.value.value != nil }
        guard acceptsAccountWork else {
            _ = session.invalidateForAccountTransition()
            return
        }
        openSessions[ObjectIdentifier(session)] = WeakOpenSession(session)
    }

    /// Resolves the locally-available wrapped original HTML (no network recovery) and keeps a prepared
    /// payload ready for the reader. When active WebView adoption is explicitly enabled, also
    /// pre-renders an off-screen WebView. Cheap to call repeatedly: it no-ops when up-to-date state is
    /// already warm.
    func warm(request: OriginalEmailWarmRequest, message: Message?, width: CGFloat?) async {
        guard acceptsAccountWork else { return }
        let warmOperationID = UUID()
        let generation = accountGeneration
        activeWarmOperations.insert(warmOperationID)
        defer { finishWarmOperation(warmOperationID) }

        let remoteImageFallbackGeneration = remoteImageFallbackBookkeeping.generation(for: request.messageId)
        rememberRemoteImageFallbackWarmContext(request: request, message: message, width: width)

        guard let warmed = await loader.warmOriginalEmailSource(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject
        ), isCurrentAccountGeneration(generation) else {
            if remoteImageFallbackBookkeeping.isCurrent(
                messageId: request.messageId,
                generation: remoteImageFallbackGeneration
            ),
               preparedPayloads.entry(for: request.messageId) == nil,
               entries[request.messageId] == nil {
                forgetRemoteImageFallbackWarmContext(messageId: request.messageId)
            }
            return
        }

        guard !Task.isCancelled else {
            if remoteImageFallbackBookkeeping.isCurrent(
                messageId: request.messageId,
                generation: remoteImageFallbackGeneration
            ),
               preparedPayloads.entry(for: request.messageId) == nil,
               entries[request.messageId] == nil {
                forgetRemoteImageFallbackWarmContext(messageId: request.messageId)
            }
            return
        }
        guard isCurrentAccountGeneration(generation) else {
            return
        }
        guard remoteImageFallbackBookkeeping.isCurrent(
            messageId: request.messageId,
            generation: remoteImageFallbackGeneration
        ) else {
            return
        }

        let preparedKey = makePreparedKey(
            messageId: request.messageId,
            sourceSignature: warmed.sourceSignature,
            wrappedHTML: warmed.html
        )
        let payload = makePayload(
            request: request,
            warmed: warmed,
            checkoutAvailability: .warming
        )
        preparedPayloads.store(
            key: preparedKey,
            request: request,
            payload: payload
        )
        applyEvictions(bookkeeping.touch(request.messageId))

        guard EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption,
              let width,
              width > 1 else {
            return
        }

        let key = makePreRenderKey(
            messageId: request.messageId,
            sourceSignature: warmed.sourceSignature,
            wrappedHTML: warmed.html,
            message: message,
            width: width
        )

        // Already warm (or warming) for this exact content + width: keep it hot and return.
        if let existing = entries[request.messageId], existing.key == key, !existing.isCheckedOut {
            existing.request = request
            existing.payload = payload
            applyEvictions(bookkeeping.touch(request.messageId))
            return
        }

        // Replace any stale (different content/width) instance for this message.
        if let stale = entries[request.messageId], !stale.isCheckedOut {
            teardown(stale)
            entries.removeValue(forKey: request.messageId)
        } else if entries[request.messageId]?.isCheckedOut == true {
            // A live instance is on screen; don't disturb it. The reader reloads on content change.
            return
        }

        let entry = makeEntry(
            key: key,
            request: request,
            payload: payload,
            prepaintSource: .visibleRowWarm,
            message: message,
            senderEmail: request.senderEmail,
            width: width,
            html: warmed.html
        )
        entries[request.messageId] = entry
        applyEvictions(bookkeeping.touch(request.messageId))
    }

    /// Starts or promotes a matching full-interactive WebView for checkout only after the user
    /// explicitly opens the full original email. A new prepaint cannot help the current open because
    /// the reader only attempts checkout once, but it can make later opens instant.
    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat
    ) {
        guard let generation = captureAccountWorkGeneration() else { return }
        prepaintAfterExplicitOpen(
            request: request,
            message: message,
            artifact: artifact,
            width: width,
            expectedAccountGeneration: generation
        )
    }

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat,
        expectedAccountGeneration: FullEmailAccountWorkGeneration?
    ) {
        guard let expectedAccountGeneration,
              isCurrentAccountGeneration(expectedAccountGeneration.value) else {
            return
        }
        guard case .html(let html) = artifact.body else {
            return
        }

        let payload = FullEmailOpenPayload(
            artifact: artifact,
            checkoutAvailability: .warming
        )

        guard width > 1,
              request.messageId == message.id,
              artifact.messageID == request.messageId,
              EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption else {
            return
        }

        let preparedKey = makePreparedKey(
            messageId: request.messageId,
            sourceSignature: artifact.sourceSignature,
            wrappedHTML: html
        )
        let key = makePreRenderKey(
            messageId: request.messageId,
            sourceSignature: artifact.sourceSignature,
            wrappedHTML: html,
            message: message,
            width: width
        )
        if let existing = entries[request.messageId] {
            guard !existing.isCheckedOut else {
                return
            }

            if existing.key == key {
                let availability: FullEmailOpenPayload.CheckoutAvailability = existing.didFinishInitialLoad
                    ? .ready
                    : .warming
                let updatedPayload = payload.withCheckoutAvailability(availability)
                preparedPayloads.store(
                    key: preparedKey,
                    request: request,
                    payload: updatedPayload
                )
                existing.request = request
                existing.payload = updatedPayload
                existing.prepaintSource = .explicitOpen
                applyEvictions(bookkeeping.touch(request.messageId))
                return
            }

            teardown(existing)
            entries.removeValue(forKey: request.messageId)
        }

        let warmingPayload = payload.withCheckoutAvailability(.warming)
        preparedPayloads.store(
            key: preparedKey,
            request: request,
            payload: warmingPayload
        )
        let entry = makeEntry(
            key: key,
            request: request,
            payload: warmingPayload,
            prepaintSource: .explicitOpen,
            message: message,
            senderEmail: request.senderEmail,
            width: width,
            html: html
        )
        entries[request.messageId] = entry
        applyEvictions(bookkeeping.touch(request.messageId))
    }

    /// Fire-and-forget warm for a message that is about to be opened (e.g. on tap). This prepares the
    /// wrapped original HTML for a later open without blocking synchronous UI code.
    func prewarmOnOpen(message: Message, width: CGFloat?) {
        guard acceptsAccountWork else { return }
        let generation = accountGeneration
        let taskID = UUID()
        let request = OriginalEmailWarmRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.prewarmTasks.removeValue(forKey: taskID) }
            guard self.isCurrentAccountGeneration(generation) else { return }
            await self.warm(request: request, message: message, width: width)
            guard self.isCurrentAccountGeneration(generation) else { return }
            guard let prepared = self.preparedOpenArtifact(
                request: request,
                message: message,
                width: width
            ) else {
                return
            }
            self.prepaintAfterExplicitOpen(
                request: request,
                message: message,
                artifact: prepared.artifact,
                width: width ?? 0
            )
        }
        prewarmTasks[taskID] = task
    }

    // MARK: Checkout / checkin

    /// Returns the prepared wrapped original-email HTML that the full reader can display immediately,
    /// provided it still matches the current local source, inline CID availability, and target width.
    func preparedOpenArtifact(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat?
    ) -> EmailReaderPreparedArtifact? {
        guard acceptsAccountWork else { return nil }
        guard let preparedEntry = preparedPayloads.entry(for: request.messageId) else {
            logOpenPayloadMiss(
                messageId: request.messageId,
                reason: "not_warmed"
            )
            return nil
        }

        let expectedKey = makePreparedKey(
            messageId: request.messageId,
            sourceSignature: preparedEntry.payload.sourceSignature,
            wrappedHTML: preparedEntry.payload.html
        )
        let currentSourceSignature = loader.currentHTMLSourceSignature(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI
        )

        switch FullEmailOpenPayloadReuseValidator.decision(
            entryKey: preparedEntry.key,
            expectedKey: expectedKey,
            entryRequest: preparedEntry.request,
            currentRequest: request,
            payload: preparedEntry.payload,
            currentSourceSignature: currentSourceSignature
        ) {
        case .reusable:
            let availability = checkoutAvailability(
                for: request.messageId,
                payload: preparedEntry.payload,
                message: message,
                width: width
            )
            OriginalEmailTelemetry.log(
                event: "open_payload_hit",
                messageId: request.messageId,
                detail: [
                    "checkoutAvailability=\(availability.rawValue)",
                    "webViewAdoption=\(EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption ? "enabled" : "disabled")"
                ].joined(separator: " ")
            )
            let metadata = message.map(EmailMetadataSnapshot.init(message:)) ?? EmailMetadataSnapshot(request: request)
            let artifact = preparedEntry.payload.artifact(
                metadata: metadata,
                message: message
            )
            return EmailReaderPreparedArtifact(
                artifact: artifact,
                checkoutAvailability: availability
            )
        case .staleSource(let currentSourceSignature):
            logOpenPayloadMiss(
                messageId: request.messageId,
                reason: "stale_source",
                detail: "currentSourceSignature=\(currentSourceSignature)"
            )
            invalidate(messageId: request.messageId)
            return nil
        case .missingCurrentHTMLSource:
            logOpenPayloadMiss(messageId: request.messageId, reason: "missing_current_html_source")
            invalidate(messageId: request.messageId)
            return nil
        case .wrapperInputsMismatch:
            logOpenPayloadMiss(messageId: request.messageId, reason: "wrapper_input_mismatch")
            invalidate(messageId: request.messageId)
            return nil
        case .keyMismatch:
            logOpenPayloadMiss(messageId: request.messageId, reason: "key_mismatch")
            return nil
        }
    }

    /// Returns a fully-painted pre-rendered WebView for the reader to display instantly, or `nil` if
    /// none matches the reader's exact content/width yet (then the reader uses the live render path).
    func checkout(
        messageId: String,
        sourceSignature: String?,
        wrappedHTML: String,
        message: Message?,
        width: CGFloat
    ) -> Checkout? {
        guard acceptsAccountWork else { return nil }
        guard canCheckoutActiveWebView(messageId: messageId) else {
            logCheckoutMiss(messageId: messageId, reason: "adoption_disabled")
            return nil
        }

        guard width > 1 else {
            logCheckoutMiss(messageId: messageId, reason: "missing_width")
            return nil
        }

        guard let sourceSignature else {
            logCheckoutMiss(messageId: messageId, reason: "missing_source_signature")
            return nil
        }

        let key = makePreRenderKey(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: wrappedHTML,
            message: message,
            width: width
        )
        guard let entry = entries[messageId] else {
            logCheckoutMiss(messageId: messageId, reason: "not_warmed")
            return nil
        }
        guard entry.key == key else {
            logCheckoutMiss(messageId: messageId, reason: "key_mismatch")
            return nil
        }
        guard entry.didFinishInitialLoad else {
            logCheckoutMiss(messageId: messageId, reason: "still_warming")
            return nil
        }
        guard !entry.isCheckedOut else {
            logCheckoutMiss(messageId: messageId, reason: "checked_out")
            return nil
        }

        entry.isCheckedOut = true
        entry.cidHandler.message = message
        host.remove(entry.webView)
        applyEvictions(bookkeeping.touch(messageId))

        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "FullEmailWebViewManager webview_checkout_hit message=\(messageId)",
            category: .ui
        )
        return Checkout(webView: entry.webView, cidHandler: entry.cidHandler)
    }

    /// Reclaims a previously checked-out WebView when the reader is dismissed, re-hosting it off-screen
    /// so a re-open is instant. Discards it if the pool no longer tracks it (evicted while displayed).
    func checkin(messageId: String, webView: WKWebView) -> Bool {
        guard acceptsAccountWork,
              let entry = entries[messageId],
              entry.webView === webView else {
            return false
        }

        entry.isCheckedOut = false
        entry.cidHandler.message = nil
        entry.webView.navigationDelegate = entry.delegate
        entry.webView.onLayoutChange = nil
        entry.webView.scrollView.setContentOffset(.zero, animated: false)
        host.host(entry.webView, width: CGFloat(entry.key.widthBucket))
        applyEvictions(bookkeeping.touch(messageId))
        return entries[messageId] === entry
    }

    // MARK: Invalidation

    func invalidate(messageId: String) {
        forgetRemoteImageFallbackWarmContext(messageId: messageId)
        preparedPayloads.remove(messageId)
        removeEntry(messageId: messageId)
    }

    func clear() {
        for entry in entries.values where !entry.isCheckedOut {
            teardown(entry)
        }
        entries = entries.filter { $0.value.isCheckedOut }
        preparedPayloads.removeAll()
        bookkeeping.removeAll()
        remoteImageFallbackBookkeeping.removeAllWarmContexts()
        remoteImageFallbackMessages.removeAll()
        for messageId in entries.keys {
            _ = bookkeeping.touch(messageId)
        }
    }

    /// Account transitions may discard even a currently checked-out reader:
    /// retaining it would keep the previous account's full HTML document alive
    /// after durable local cleanup has completed.
    func clearForAccountTransition() async {
        acceptsAccountWork = false
        accountGeneration &+= 1
        let tasks = Array(prewarmTasks.values)
        tasks.forEach { $0.cancel() }
        let sessions = openSessions.values.compactMap(\.value)
        openSessions.removeAll(keepingCapacity: false)
        let sessionSourceTasks = sessions.flatMap { $0.invalidateForAccountTransition() }
        let entryWebViews = entries.values.map(\.webView)

        for entry in entries.values {
            scrubForAccountTransition(entry)
        }
        entries.removeAll()
        preparedPayloads.removeAll()
        bookkeeping.removeAll()
        remoteImageFallbackBookkeeping.removeAllWarmContexts()
        remoteImageFallbackMessages.removeAll()

        await FullEmailReaderAccountBoundaryRegistry.shared.clearForAccountTransition(
            additionallyAwaiting: entryWebViews
        )

        for task in tasks {
            await task.value
        }
        _ = await withSoftTimeout(seconds: 1.0) {
            for task in sessionSourceTasks {
                _ = await task.value
            }
        }
        if !activeWarmOperations.isEmpty {
            await withCheckedContinuation { continuation in
                warmDrainWaiters.append(continuation)
            }
        }
        prewarmTasks.removeAll()
    }

    func reopenAccountWork() {
        // Reopen the process-wide reader registry before the pool's own guard.
        // If a leaked warm operation keeps the pool closed, registerOpenSession
        // already invalidates every newly created FullEmailOpenSession, so full
        // email stays unusable either way until relaunch — but the registry
        // must not stay latched with it: a closed registry would silently
        // scrub any future reader not gated by an open session, and this
        // manager is the registry's sole close/reopen owner (AuthSession
        // reaches the registry only through here), so nothing else could ever
        // reopen it.
        FullEmailReaderAccountBoundaryRegistry.shared.reopenAccountWork()
        guard activeWarmOperations.isEmpty else {
            Log.error(
                "Refusing to reopen the full-email pool while closed-account warm operations remain",
                category: .ui
            )
            return
        }
        accountGeneration &+= 1
        acceptsAccountWork = true
    }

    private func handleRemoteImageFallbackDidWarm(messageId: String) async {
        guard acceptsAccountWork else { return }
        let generation = accountGeneration
        remoteImageFallbackBookkeeping.markFallbackWarmed(messageId: messageId)
        let warmContext = remoteImageFallbackBookkeeping.warmContext(for: messageId)
        preparedPayloads.remove(messageId)
        removeEntry(messageId: messageId)
        await loader.invalidateWarmedOriginalEmailSource(messageId: messageId)
        guard isCurrentAccountGeneration(generation) else { return }

        guard let warmContext else {
            return
        }

        guard remoteImageFallbackBookkeeping.warmContext(for: messageId) == warmContext else {
            return
        }
        let message = remoteImageFallbackMessages[messageId]
        await warm(
            request: warmContext.request,
            message: message,
            width: warmContext.width
        )
    }

    // MARK: - Internals

    private func makePreparedKey(
        messageId: String,
        sourceSignature: String,
        wrappedHTML: String
    ) -> FullEmailPreparedArtifactKey {
        FullEmailPreparedArtifactKey.make(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: wrappedHTML
        )
    }

    private func makePreRenderKey(
        messageId: String,
        sourceSignature: String,
        wrappedHTML: String,
        message: Message?,
        width: CGFloat
    ) -> FullEmailWebViewPreRenderKey {
        let cidFingerprint = InlineCIDAttachmentAvailabilityFingerprint.make(
            html: wrappedHTML,
            message: message
        )
        return FullEmailWebViewPreRenderKey.make(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: wrappedHTML,
            cidAvailabilityFingerprint: cidFingerprint,
            width: width
        )
    }

    private func makePayload(
        request: OriginalEmailWarmRequest,
        warmed: WarmedOriginalEmailHTML,
        checkoutAvailability: FullEmailOpenPayload.CheckoutAvailability
    ) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: request.messageId,
            sourceSignature: warmed.sourceSignature,
            html: warmed.html,
            presentation: .html,
            sourceKind: warmed.sourceKind,
            sourceLocation: warmed.sourceLocation,
            hasHTMLSource: warmed.hasHTMLSource,
            checkoutAvailability: checkoutAvailability
        )
    }

    private func checkoutAvailability(
        for messageId: String,
        payload: FullEmailOpenPayload,
        message: Message?,
        width: CGFloat?
    ) -> FullEmailOpenPayload.CheckoutAvailability {
        guard let width,
              width > 1,
              canCheckoutActiveWebView(messageId: messageId),
              let entry = entries[messageId],
              entry.key == makePreRenderKey(
                messageId: messageId,
                sourceSignature: payload.sourceSignature,
                wrappedHTML: payload.html,
                message: message,
                width: width
              ) else {
            return .warming
        }

        return entry.didFinishInitialLoad ? .ready : .warming
    }

    private func makeEntry(
        key: FullEmailWebViewPreRenderKey,
        request: OriginalEmailWarmRequest,
        payload: FullEmailOpenPayload,
        prepaintSource: Entry.PrepaintSource,
        message: Message?,
        senderEmail: String?,
        width: CGFloat,
        html: String
    ) -> Entry {
        let cidHandler = CIDSchemeHandler(message: message)
        let configuration = FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        let webView = LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: width, height: host.preferredHeight()),
            configuration: configuration
        )
        FullInteractiveEmailWebView.applySettings(to: webView)
        FullInteractiveEmailWebView.applyBackgroundAppearance(to: webView)

        let delegate = WarmNavigationDelegate()
        webView.navigationDelegate = delegate
        let entry = Entry(
            key: key,
            request: request,
            payload: payload,
            prepaintSource: prepaintSource,
            webView: webView,
            cidHandler: cidHandler,
            delegate: delegate
        )
        delegate.onFinish = { [weak self, weak entry] in
            self?.finalizeWarm(entry)
        }

        host.host(webView, width: width)
        let baseURL = FullInteractiveEmailWebView.baseURL(message: message, senderEmail: senderEmail)
        webView.loadHTMLString(html, baseURL: baseURL)
        return entry
    }

    private func canCheckoutActiveWebView(messageId: String) -> Bool {
        EmailReaderRenderingConfiguration.enablesOffscreenWebViewAdoption && entries[messageId] != nil
    }

    /// Marks a warmed instance ready only after forcing a render pass. `WKNavigationDelegate.didFinish`
    /// fires on load completion, not paint completion; taking a snapshot guarantees the content has
    /// actually been rasterized, so adopting it into the on-screen reader composites an already-painted
    /// view with no first-paint flash. Snapshot errors are non-fatal — the content still loaded.
    private func finalizeWarm(_ entry: Entry?) {
        guard let entry, !entry.didFinishInitialLoad else {
            return
        }

        let bounds = entry.webView.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            entry.didFinishInitialLoad = true
            return
        }

        entry.webView.layoutIfNeeded()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        entry.webView.takeSnapshot(with: configuration) { [weak entry] _, _ in
            entry?.didFinishInitialLoad = true
        }
    }

    private func applyEvictions(_ evicted: [String]) {
        for messageId in evicted {
            preparedPayloads.remove(messageId)
            forgetRemoteImageFallbackWarmContext(messageId: messageId)
            guard let entry = entries.removeValue(forKey: messageId) else {
                continue
            }
            // A checked-out instance is owned by the reader; just drop our reference (it will be
            // discarded on checkin since we no longer track it).
            if !entry.isCheckedOut {
                teardown(entry)
            }
        }
    }

    @discardableResult
    private func removeEntry(messageId: String) -> Entry? {
        bookkeeping.remove(messageId)
        guard let entry = entries.removeValue(forKey: messageId) else {
            return nil
        }
        if !entry.isCheckedOut {
            teardown(entry)
        }
        return entry
    }

    /// Ordinary teardown deliberately skips the blank-document navigation: it
    /// only ever releases pool-owned, non-checked-out entries, where the pool
    /// holds the last strong reference and the WebView deallocates with its
    /// content. Account transitions route through scrubForAccountTransition,
    /// which alone pays the blank-load.
    private func teardown(_ entry: Entry) {
        // Fail closed if a future caller breaks the non-checked-out contract:
        // a checked-out entry may be externally retained, so releasing it
        // without the blank-load would leave its DOM resident.
        guard !entry.isCheckedOut else {
            scrubForAccountTransition(entry)
            return
        }
        prepareForTeardown(entry)
        host.remove(entry.webView)
    }

    /// A checked-out reader may still retain this WKWebView after the pool
    /// drops its entry. Replace the old account's live DOM immediately so a
    /// later SwiftUI dismantle/checkin cannot leave that content resident.
    private func scrubForAccountTransition(_ entry: Entry) {
        prepareForTeardown(entry)
        entry.webView.loadHTMLString("", baseURL: URL(string: "about:blank"))
        host.remove(entry.webView)
    }

    private func prepareForTeardown(_ entry: Entry) {
        entry.webView.stopLoading()
        entry.webView.navigationDelegate = nil
        entry.webView.onLayoutChange = nil
        entry.cidHandler.message = nil
    }

    private func rememberRemoteImageFallbackWarmContext(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat?
    ) {
        remoteImageFallbackBookkeeping.rememberWarmContext(request: request, width: width)
        if let message {
            remoteImageFallbackMessages[request.messageId] = message
        } else {
            remoteImageFallbackMessages.removeValue(forKey: request.messageId)
        }
    }

    private func forgetRemoteImageFallbackWarmContext(messageId: String) {
        remoteImageFallbackBookkeeping.removeWarmContext(messageId: messageId)
        remoteImageFallbackMessages.removeValue(forKey: messageId)
    }

    private func logOpenPayloadMiss(
        messageId: String,
        reason: String,
        detail: String? = nil
    ) {
        OriginalEmailTelemetry.log(
            event: "open_payload_miss",
            messageId: messageId,
            detail: [detail, "reason=\(reason)"].compactMap { $0 }.joined(separator: " ")
        )
    }

    private func logCheckoutMiss(messageId: String, reason: String) {
        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "FullEmailWebViewManager webview_checkout_miss message=\(messageId) reason=\(reason)",
            category: .ui
        )
    }

    private func isCurrentAccountGeneration(_ generation: UInt64) -> Bool {
        acceptsAccountWork && generation == accountGeneration
    }

    private func finishWarmOperation(_ id: UUID) {
        activeWarmOperations.remove(id)
        guard activeWarmOperations.isEmpty, !warmDrainWaiters.isEmpty else {
            return
        }
        let waiters = warmDrainWaiters
        warmDrainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    // Test seams.
    var trackedMessageIdsForTesting: Set<String> {
        Set(entries.keys).union(preparedPayloads.messageIds)
    }

    func hasPreparedPayloadForTesting(messageId: String) -> Bool {
        preparedPayloads.entry(for: messageId) != nil
    }

    func hasRemoteImageFallbackWarmContextForTesting(messageId: String) -> Bool {
        remoteImageFallbackBookkeeping.warmContext(for: messageId) != nil
    }

    func isWarmedForTesting(messageId: String) -> Bool {
        entries[messageId]?.didFinishInitialLoad == true
    }

    func hasPrerenderedWebViewEntryForTesting(messageId: String) -> Bool {
        entries[messageId] != nil
    }

    func webViewForTesting(messageId: String) -> LayoutAwareWKWebView? {
        entries[messageId]?.webView
    }

    func markInitialLoadFinishedForTesting(messageId: String) {
        entries[messageId]?.didFinishInitialLoad = true
    }

    var acceptsAccountWorkForTesting: Bool {
        acceptsAccountWork
    }

    func beginWarmOperationForTesting() -> UUID {
        let id = UUID()
        activeWarmOperations.insert(id)
        return id
    }

    func finishWarmOperationForTesting(_ id: UUID) {
        finishWarmOperation(id)
    }
}

// MARK: - Warm navigation delegate

/// Minimal navigation delegate used while a WebView is pre-rendering off-screen. It only needs to
/// allow the initial load and report first paint; link handling is the live coordinator's job once
/// the instance is adopted (the off-screen instance is non-interactive).
@MainActor
private final class WarmNavigationDelegate: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        switch FullInteractiveEmailWebView.navigationDecision(
            navigationType: navigationAction.navigationType,
            url: navigationAction.request.url
        ) {
        case .allow:
            decisionHandler(.allow)
        case .cancel, .blockedPrivateNetwork, .openExternally:
            decisionHandler(.cancel)
        }
    }
}

// MARK: - Off-screen hosting window

/// Hosts pre-rendering WebViews in a window that is part of the active scene but positioned beyond
/// the screen edge, so WebKit actually lays out and paints content (a windowless WebView may defer
/// rasterization until first display, which would reintroduce a paint when adopted).
@MainActor
private final class OffscreenWebViewHost {
    private var window: UIWindow?

    func host(_ view: UIView, width: CGFloat) {
        guard let window = ensureWindow() else {
            return
        }
        view.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: window.bounds.height)
        )
        view.autoresizingMask = []
        window.rootViewController?.view.addSubview(view)
    }

    func remove(_ view: UIView) {
        view.removeFromSuperview()
    }

    func preferredHeight() -> CGFloat {
        ensureWindow()?.bounds.height ?? FullEmailWebViewMetrics.activeWindowScene()?.screen.bounds.height ?? 0
    }

    private func ensureWindow() -> UIWindow? {
        if let window {
            return window
        }
        guard let scene = FullEmailWebViewMetrics.activeWindowScene() else {
            return nil
        }

        let screenBounds = scene.screen.bounds
        let window = UIWindow(windowScene: scene)
        // Positioned fully beyond the left edge: never visible to the user, but still part of the
        // scene so the render server composites it and WebKit paints the content.
        window.frame = CGRect(
            x: -screenBounds.width - 100,
            y: 0,
            width: screenBounds.width,
            height: screenBounds.height
        )
        window.windowLevel = UIWindow.Level.normal - 1
        window.isUserInteractionEnabled = false
        let rootViewController = UIViewController()
        rootViewController.view.backgroundColor = .clear
        window.rootViewController = rootViewController
        window.isHidden = false
        self.window = window
        return window
    }
}
