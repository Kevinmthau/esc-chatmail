import Foundation
import UIKit
import WebKit

struct EmailPreviewSnapshotRequest {
    let html: String
    let cacheKey: String
    let containerWidth: CGFloat
    let isDarkMode: Bool
    let senderEmail: String?
    let message: Message?
}

struct EmailPreviewSnapshotResult {
    let image: UIImage
    let displayHeight: CGFloat
    let pixelScale: CGFloat
    let cacheKey: String
}

enum EmailPreviewSnapshotRenderError: Error {
    case invalidWidth
    case navigationFailed(Error)
    case timeout
    case snapshotUnavailable
}

enum EmailPreviewSnapshotAppearance {
    /// Snapshot previews follow the preview policy, not the original-email policy:
    /// render against the requested app appearance so cached images match chat UI.
    static func userInterfaceStyle(isDarkMode: Bool) -> UIUserInterfaceStyle {
        isDarkMode ? .dark : .light
    }

    /// Snapshot previews use the same wrapper theme as live preview WebViews.
    static func theme(isDarkMode: Bool) -> HTMLDisplayWrapper.Theme {
        HTMLDisplayWrapper.theme(isDarkMode: isDarkMode, displayPurpose: .preview)
    }
}

@MainActor
protocol EmailPreviewSnapshotRendering: AnyObject {
    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult
}

@MainActor
final class EmailPreviewSnapshotRenderer: EmailPreviewSnapshotRendering {
    static let shared = EmailPreviewSnapshotRenderer()

    private init() {}

    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult {
        try Task.checkCancellation()
        let session = try EmailPreviewSnapshotRenderSession(request: request)
        return try await withTaskCancellationHandler {
            try await session.render()
        } onCancel: {
            Task { @MainActor in
                session.cancel()
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

@MainActor
private final class EmailPreviewSnapshotRenderSession: NSObject, WKNavigationDelegate {
    private let request: EmailPreviewSnapshotRequest
    private let webView: WKWebView
    private let cidHandler: CIDSchemeHandler
    private var continuation: CheckedContinuation<EmailPreviewSnapshotResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var didComplete = false
    private let scale: CGFloat

    init(request: EmailPreviewSnapshotRequest) throws {
        guard request.containerWidth > 1 else {
            throw EmailPreviewSnapshotRenderError.invalidWidth
        }

        self.request = request
        self.scale = HTMLPreviewScaleCalculator.previewScale(
            defaultScale: 0.5,
            containerWidth: request.containerWidth,
            html: request.html
        )

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let cidHandler = CIDSchemeHandler(message: request.message)
        self.cidHandler = cidHandler
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: "cid")

        self.webView = WKWebView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: request.containerWidth,
                height: HTMLPreviewSizing.maximumPreviewHeight
            ),
            configuration: configuration
        )

        super.init()

        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isUserInteractionEnabled = false
        applyBackgroundAppearance()
    }

    func render() async throws -> EmailPreviewSnapshotResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EmailPreviewSnapshotResult, Error>) in
            guard !didComplete else {
                continuation.resume(throwing: CancellationError())
                return
            }

            self.continuation = continuation
            startTimeout()

            let htmlToLoad = HTMLPreviewScalingWrapper.wrap(request.html, scale: scale)
            let baseURL = EmailSenderBaseURLResolver.baseURL(
                from: request.message?.senderEmail ?? request.senderEmail
            ) ?? URL(string: "about:blank")

            webView.loadHTMLString(htmlToLoad, baseURL: baseURL)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func startTimeout() {
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            self?.finish(.failure(EmailPreviewSnapshotRenderError.timeout))
        }
    }

    private func applyBackgroundAppearance() {
        webView.isOpaque = false
        // Snapshot previews explicitly set dark/light traits from the request so
        // offscreen rendering matches the app appearance encoded into the cache key.
        webView.overrideUserInterfaceStyle = EmailPreviewSnapshotAppearance.userInterfaceStyle(
            isDarkMode: request.isDarkMode
        )
        let theme = EmailPreviewSnapshotAppearance.theme(isDarkMode: request.isDarkMode)
        let color = UIColor(hex: theme.backgroundColorHex) ?? .systemBackground
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        webView.underPageBackgroundColor = color
    }

    private func finish(_ result: Result<EmailPreviewSnapshotResult, Error>) {
        guard !didComplete else {
            return
        }

        didComplete = true
        timeoutTask?.cancel()
        settleTask?.cancel()
        settleTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private func finishAfterLoadSettles() async {
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            guard !didComplete else { return }

            let firstHeight = try await measureRenderedHeight()
            try await Task.sleep(nanoseconds: 750_000_000)
            try Task.checkCancellation()
            guard !didComplete else { return }

            let secondHeight = try await measureRenderedHeight()
            guard !didComplete else { return }

            let measuredHeight = max(
                HTMLPreviewSizing.defaultPreviewHeight,
                max(firstHeight, secondHeight)
            )
            let displayHeight = HTMLPreviewSizing.clampedHeight(measuredHeight)

            webView.frame = CGRect(
                x: 0,
                y: 0,
                width: request.containerWidth,
                height: displayHeight
            )
            webView.layoutIfNeeded()
            guard !didComplete else { return }

            let image = try await snapshot(displayHeight: displayHeight)
            guard !didComplete else { return }

            guard image.size.width > 0, image.size.height > 0 else {
                finish(.failure(EmailPreviewSnapshotRenderError.snapshotUnavailable))
                return
            }

            finish(
                .success(
                    EmailPreviewSnapshotResult(
                        image: image,
                        displayHeight: displayHeight,
                        pixelScale: image.scale,
                        cacheKey: request.cacheKey
                    )
                )
            )
        } catch {
            finish(.failure(error))
        }
    }

    private func measureRenderedHeight() async throws -> CGFloat {
        let script = HTMLPreviewSnapshotHeightMeasurementScript.script(scale: scale)
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let height = CGFloat((result as? NSNumber)?.doubleValue ?? 0)
                continuation.resume(returning: height)
            }
        }
    }

    private func snapshot(displayHeight: CGFloat) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(
                x: 0,
                y: 0,
                width: request.containerWidth,
                height: displayHeight
            )

            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    continuation.resume(throwing: EmailPreviewSnapshotRenderError.snapshotUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            await self?.finishAfterLoadSettles()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(EmailPreviewSnapshotRenderError.navigationFailed(error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(EmailPreviewSnapshotRenderError.navigationFailed(error)))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .other || navigationAction.navigationType == .reload {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}
