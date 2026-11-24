import Foundation
import WebKit

/// Shared load-readiness / reload-signature core for the email WebView
/// coordinators (`BaseEmailWebView.Coordinator` and
/// `FullEmailReaderWebView.Coordinator`). Owns the loaded-content bookkeeping
/// and the readiness gate; the coordinators compose it and inject their
/// mode-specific pieces (current content/signature, the height requirement,
/// and any side effect that must run when the recorded signature changes).
final class EmailWebViewLoadCoordination {
    enum LoadReadiness: Equatable {
        case ready
        case deferred(reason: String)
    }

    private(set) var lastLoadedContent: String = ""
    private(set) var lastLoadedReloadSignature: String = ""
    private(set) var hasFinishedLoad = false
    /// The content and signature last reloaded after the web view's WebContent process terminated.
    /// See `admitsReloadAfterWebContentTermination`.
    private var webContentTerminationReload: WebContentTerminationReload?

    private struct WebContentTerminationReload {
        let content: String
        let reloadSignature: String
        var count: Int
        var wasDisplayed: Bool
    }

    /// How many times terminations may reload one content and signature.
    static let maximumWebContentTerminationReloads = 3

    /// Preview WebViews size themselves from the reported height, so
    /// readiness requires a measured height; the full reader does not.
    private let requiresViewportHeight: Bool
    /// Runs before every recorded-signature change (record/adopt/reset); the
    /// full reader invalidates its pending paint confirmation here.
    private let onSignatureChange: () -> Void

    init(
        requiresViewportHeight: Bool,
        onSignatureChange: @escaping () -> Void = {}
    ) {
        self.requiresViewportHeight = requiresViewportHeight
        self.onSignatureChange = onSignatureChange
    }

    func needsReload(content: String, reloadSignature: String) -> Bool {
        lastLoadedContent != content || lastLoadedReloadSignature != reloadSignature
    }

    func loadReadiness(
        needsReload: Bool,
        isLoading: Bool,
        windowPresent: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> LoadReadiness {
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

        if requiresViewportHeight {
            guard height > 1 else {
                return .deferred(reason: "missing-height")
            }
        }

        return .ready
    }

    func recordLoadedSignature(content: String, reloadSignature: String) {
        onSignatureChange()
        lastLoadedContent = content
        lastLoadedReloadSignature = reloadSignature
        hasFinishedLoad = false
    }

    /// Marks content as already loaded and painted (adopted pre-rendered
    /// WebViews), so `needsReload` is false without a fresh load.
    func adoptAlreadyLoadedContent(content: String, reloadSignature: String) {
        onSignatureChange()
        lastLoadedContent = content
        lastLoadedReloadSignature = reloadSignature
        hasFinishedLoad = true
    }

    func recordFinishedLoad() {
        hasFinishedLoad = true
    }

    func resetLoadedSignatureAfterFailure() {
        onSignatureChange()
        lastLoadedContent = ""
        lastLoadedReloadSignature = ""
        hasFinishedLoad = false
    }

    @discardableResult
    func resetLoadedSignatureAfterFailure(for error: Error) -> Bool {
        if Self.isCancelledNavigationError(error), hasFinishedLoad {
            return false
        }
        resetLoadedSignatureAfterFailure()
        return true
    }

    /// Answers whether a WebContent process termination may reload this content. The coordinators
    /// reload their own content when the process dies, and `updateWebView` reloads whenever
    /// `needsReload` holds, so a page that crashes WebKit as it loads would reload for as long as
    /// the view is on screen. A termination is admitted for content not reloaded before; for the
    /// same content and signature again only once the last reload was displayed
    /// (`recordDisplayedAfterWebContentTermination`), and at most
    /// `maximumWebContentTerminationReloads` times. So a page that takes the process down before it
    /// shows is reloaded once, a view killed each time the app is suspended recovers each time, up
    /// to the cap, and a page that shows and then crashes is reloaded no more than the cap. When
    /// this answers `false` the caller leaves the signature recorded, so nothing reloads the content
    /// until it or its signature changes.
    func admitsReloadAfterWebContentTermination(content: String, reloadSignature: String) -> Bool {
        if var reload = webContentTerminationReload,
           reload.content == content,
           reload.reloadSignature == reloadSignature {
            guard reload.wasDisplayed,
                  reload.count < Self.maximumWebContentTerminationReloads else {
                return false
            }
            reload.count += 1
            reload.wasDisplayed = false
            webContentTerminationReload = reload
            return true
        }
        webContentTerminationReload = WebContentTerminationReload(
            content: content,
            reloadSignature: reloadSignature,
            count: 1,
            wasDisplayed: false
        )
        return true
    }

    /// The current load was displayed: the reader confirmed its paint, the preview finished it.
    /// After a termination's reload this lets a later termination reload again.
    func recordDisplayedAfterWebContentTermination() {
        webContentTerminationReload?.wasDisplayed = true
    }

    /// A navigation that failed because its WebContent process died. The coordinators ignore it:
    /// `webViewWebContentProcessDidTerminate` owns that recovery, and a failure handled as an
    /// ordinary one would reset the signature behind the termination's reload, which is how the
    /// latch above would be undone into a reload loop. On the iOS 27.0 simulator no
    /// failure arrived at all for a navigation the process took with it (2026-11-24, a SIGKILL of
    /// the process mid-load); this is for a WebKit that reports one.
    static func isWebContentProcessTerminationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == WKErrorDomain
            && nsError.code == WKError.Code.webContentProcessTerminated.rawValue
    }

    static func isCancelledNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isCancelledNavigationError(underlyingError)
        }

        return false
    }

    static func messageIdentitySignature(messageId: String?) -> String {
        guard let messageId else {
            return "message:none"
        }
        return "message:\(messageId)"
    }
}
