import Foundation
import UIKit
import WebKit
import CryptoKit

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
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = [.phoneNumber, .link, .address]
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
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

    /// Pure navigation decision for the full-interactive WebView, shared by the live `Coordinator`
    /// (which performs the side effects — opening external URLs, logging blocked links) and the
    /// off-screen `WarmNavigationDelegate` (which has no side effects — it permits the `.allow` cases
    /// and cancels the link-opening and blocked-link cases). Keeping the decision pure lets it be
    /// unit-tested without WebKit.
    static func navigationDecision(
        navigationType: WKNavigationType,
        url: URL?
    ) -> NavigationDecision {
        // Allow initial load and resource loads first (before other checks). This is critical for
        // loadHTMLString with an about:blank baseURL.
        if navigationType == .other || navigationType == .reload {
            return .allow
        }

        if let url {
            let urlString = url.absoluteString
            // Block obviously malformed URLs.
            if urlString.isEmpty || urlString == "about:blank" {
                return .cancel
            }
            // Block unsupported schemes that cause errors. Note: "cid" is NOT blocked — it is handled
            // by CIDSchemeHandler.
            let scheme = url.scheme?.lowercased() ?? ""
            let unsupportedSchemes = ["javascript", "vbscript", "file"]
            if unsupportedSchemes.contains(scheme) {
                return .cancel
            }
        }

        // Handle link clicks.
        if navigationType == .linkActivated, let url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "x-apple-data-detectors" {
                return .allow
            }
            if scheme == "http" || scheme == "https",
               PrivateNetworkAddressDetector.isPrivateOrReserved(url) {
                return .blockedPrivateNetwork(url)
            }
            return .openExternally(url)
        }

        return .allow
    }
}

// MARK: - Metrics

enum FullEmailWebViewMetrics {
    /// The width the full original-email reader renders at. The reader is presented as a full-width
    /// sheet, so on iPhone this equals the active scene's screen width. Both warming and checkout use
    /// this single value so their pre-render keys agree. Returns 0 when no scene is available, which
    /// callers treat as "skip pre-rendering and use the live path."
    @MainActor
    static func fullViewWidth() -> CGFloat {
        guard let scene = activeWindowScene() else {
            return 0
        }
        return scene.screen.bounds.width
    }

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
        let digest = SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(text.utf8.count):\(digest)"
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
}

enum FullEmailOpenPayloadReuseDecision: Equatable {
    case reusable
    case missingCurrentHTMLSource
    case staleSource(currentSourceSignature: String)
    case wrapperInputsMismatch
    case keyMismatch
}

enum FullEmailWebViewAdoptionPolicy {
    static let enableLaunchArgument = "-ESCEnableFullEmailWebViewAdoption"
    static let enableEnvironmentKey = "ESC_ENABLE_FULL_EMAIL_WEBVIEW_ADOPTION"
    static let disableLaunchArgument = "-ESCDisableFullEmailWebViewAdoption"
    static let disableEnvironmentKey = "ESC_DISABLE_FULL_EMAIL_WEBVIEW_ADOPTION"

    // Backward-compatible aliases for the opt-in switch.
    static let launchArgument = enableLaunchArgument
    static let environmentKey = enableEnvironmentKey

    static var allowsPrerenderedWebViewAdoption: Bool {
        isEnabled(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func isEnabled(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.contains(disableLaunchArgument) || isEnabledEnvironmentValue(environment[disableEnvironmentKey]) {
            return false
        }

        if arguments.contains(enableLaunchArgument) || isEnabledEnvironmentValue(environment[enableEnvironmentKey]) {
            return true
        }

        return false
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
        SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
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
        entryKey: FullEmailWebViewPreRenderKey,
        expectedKey: FullEmailWebViewPreRenderKey,
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

@MainActor
protocol FullEmailOpening: AnyObject {
    func preparedOpenPayload(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat
    ) -> FullEmailOpenPayload?

    func prewarmOnOpen(message: Message)
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
        let width: CGFloat
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

    mutating func rememberWarmContext(request: OriginalEmailWarmRequest, width: CGFloat) {
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
        let key: FullEmailWebViewPreRenderKey
        var request: OriginalEmailWarmRequest
        var payload: FullEmailOpenPayload
    }

    private var entries: [String: Entry] = [:]

    mutating func store(
        key: FullEmailWebViewPreRenderKey,
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
/// opt-in through `FullEmailWebViewAdoptionPolicy`, and active WebView warming must not happen from
/// scroll-time visible-row warming unless that policy is explicitly enabled.
@MainActor
final class FullEmailWebViewManager: FullEmailOpening {
    static let shared = FullEmailWebViewManager()

    struct Checkout {
        let webView: LayoutAwareWKWebView
        let cidHandler: CIDSchemeHandler
    }

    private final class Entry {
        let key: FullEmailWebViewPreRenderKey
        var request: OriginalEmailWarmRequest
        var payload: FullEmailOpenPayload
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
            webView: LayoutAwareWKWebView,
            cidHandler: CIDSchemeHandler,
            delegate: WarmNavigationDelegate
        ) {
            self.key = key
            self.request = request
            self.payload = payload
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

    /// Resolves the locally-available wrapped original HTML (no network recovery) and keeps a prepared
    /// payload ready for the reader. When active WebView adoption is explicitly enabled, also
    /// pre-renders an off-screen WebView. Cheap to call repeatedly: it no-ops when up-to-date state is
    /// already warm.
    func warm(request: OriginalEmailWarmRequest, message: Message?, width: CGFloat) async {
        guard width > 1 else {
            return
        }
        let remoteImageFallbackGeneration = remoteImageFallbackBookkeeping.generation(for: request.messageId)
        rememberRemoteImageFallbackWarmContext(request: request, message: message, width: width)

        guard let warmed = await loader.warmOriginalEmailSource(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject
        ) else {
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
        guard remoteImageFallbackBookkeeping.isCurrent(
            messageId: request.messageId,
            generation: remoteImageFallbackGeneration
        ) else {
            return
        }

        let key = makeKey(
            messageId: request.messageId,
            sourceSignature: warmed.sourceSignature,
            wrappedHTML: warmed.html,
            message: message,
            width: width
        )
        let payload = makePayload(
            request: request,
            warmed: warmed,
            checkoutAvailability: .warming
        )
        preparedPayloads.store(
            key: key,
            request: request,
            payload: payload
        )
        applyEvictions(bookkeeping.touch(request.messageId))

        guard FullEmailWebViewAdoptionPolicy.allowsPrerenderedWebViewAdoption else {
            return
        }

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
            message: message,
            senderEmail: request.senderEmail,
            width: width,
            html: warmed.html
        )
        entries[request.messageId] = entry
        applyEvictions(bookkeeping.touch(request.messageId))
    }

    /// Fire-and-forget warm for a message that is about to be opened (e.g. on tap). This prepares the
    /// wrapped original HTML for a later open without blocking synchronous UI code.
    func prewarmOnOpen(message: Message) {
        let request = OriginalEmailWarmRequest(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject
        )
        let width = FullEmailWebViewMetrics.fullViewWidth()
        Task { @MainActor in
            await warm(request: request, message: message, width: width)
        }
    }

    // MARK: Checkout / checkin

    /// Returns the prepared wrapped original-email HTML that the full reader can display immediately,
    /// provided it still matches the current local source, inline CID availability, and target width.
    func preparedOpenPayload(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat
    ) -> FullEmailOpenPayload? {
        guard width > 1 else {
            logOpenPayloadMiss(messageId: request.messageId, reason: "missing_width")
            return nil
        }

        guard let preparedEntry = preparedPayloads.entry(for: request.messageId) else {
            logOpenPayloadMiss(
                messageId: request.messageId,
                reason: "not_warmed"
            )
            return nil
        }

        let expectedKey = makeKey(
            messageId: request.messageId,
            sourceSignature: preparedEntry.payload.sourceSignature,
            wrappedHTML: preparedEntry.payload.html,
            message: message,
            width: width
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
            let availability = checkoutAvailability(for: request.messageId, matching: preparedEntry.key)
            OriginalEmailTelemetry.log(
                event: "open_payload_hit",
                messageId: request.messageId,
                detail: [
                    "checkoutAvailability=\(availability.rawValue)",
                    "webViewAdoption=\(FullEmailWebViewAdoptionPolicy.allowsPrerenderedWebViewAdoption ? "enabled" : "disabled")"
                ].joined(separator: " ")
            )
            return preparedEntry.payload.withCheckoutAvailability(availability)
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
        guard FullEmailWebViewAdoptionPolicy.allowsPrerenderedWebViewAdoption else {
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

        let key = makeKey(
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
    func checkin(messageId: String, webView: WKWebView) {
        guard let entry = entries[messageId], entry.webView === webView else {
            return
        }

        entry.isCheckedOut = false
        entry.webView.navigationDelegate = entry.delegate
        entry.webView.onLayoutChange = nil
        entry.webView.scrollView.setContentOffset(.zero, animated: false)
        host.host(entry.webView)
        applyEvictions(bookkeeping.touch(messageId))
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

    private func handleRemoteImageFallbackDidWarm(messageId: String) async {
        remoteImageFallbackBookkeeping.markFallbackWarmed(messageId: messageId)
        let warmContext = remoteImageFallbackBookkeeping.warmContext(for: messageId)
        preparedPayloads.remove(messageId)
        removeEntry(messageId: messageId)
        await loader.invalidateWarmedOriginalEmailSource(messageId: messageId)

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

    private func makeKey(
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
        matching key: FullEmailWebViewPreRenderKey
    ) -> FullEmailOpenPayload.CheckoutAvailability {
        guard FullEmailWebViewAdoptionPolicy.allowsPrerenderedWebViewAdoption,
              let entry = entries[messageId],
              entry.key == key else {
            return .warming
        }

        return entry.didFinishInitialLoad ? .ready : .warming
    }

    private func makeEntry(
        key: FullEmailWebViewPreRenderKey,
        request: OriginalEmailWarmRequest,
        payload: FullEmailOpenPayload,
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
            webView: webView,
            cidHandler: cidHandler,
            delegate: delegate
        )
        delegate.onFinish = { [weak self, weak entry] in
            self?.finalizeWarm(entry)
        }

        host.host(webView)
        let baseURL = FullInteractiveEmailWebView.baseURL(message: message, senderEmail: senderEmail)
        webView.loadHTMLString(html, baseURL: baseURL)
        return entry
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

    private func teardown(_ entry: Entry) {
        entry.webView.stopLoading()
        entry.webView.navigationDelegate = nil
        entry.webView.onLayoutChange = nil
        host.remove(entry.webView)
    }

    private func rememberRemoteImageFallbackWarmContext(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat
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

    func host(_ view: UIView) {
        guard let window = ensureWindow() else {
            return
        }
        view.frame = CGRect(origin: .zero, size: window.bounds.size)
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
