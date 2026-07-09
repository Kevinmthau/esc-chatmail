import Foundation

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
