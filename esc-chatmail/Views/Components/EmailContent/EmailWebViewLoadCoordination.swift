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
    private var webContentTerminationReload: (content: String, reloadSignature: String)?

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

    /// Answers whether a WebContent process termination may reload this content: once for each
    /// content and signature, then no more. The coordinators reload their own content when the
    /// process dies, and `updateWebView` reloads whenever `needsReload` holds, so a page that
    /// crashes WebKit every time it loads would reload for as long as the view is on screen. The
    /// second termination of the same content is answered `false`, and the caller then leaves the
    /// signature recorded, so nothing reloads it until the content or its signature changes.
    func admitsReloadAfterWebContentTermination(content: String, reloadSignature: String) -> Bool {
        if let webContentTerminationReload,
           webContentTerminationReload.content == content,
           webContentTerminationReload.reloadSignature == reloadSignature {
            return false
        }
        webContentTerminationReload = (content, reloadSignature)
        return true
    }

    /// A navigation that failed because its WebContent process died. The coordinators ignore it:
    /// `webViewWebContentProcessDidTerminate` owns that recovery, and a failure handled as an
    /// ordinary one would reset the signature behind the termination's reload, which is how the
    /// once-only latch above would be undone into a reload loop. On the iOS 27.0 simulator no
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
