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
protocol EmailPreviewSnapshotRenderScheduling: AnyObject {
    func render(
        request: EmailPreviewSnapshotRequest,
        operation: @escaping @MainActor () async throws -> EmailPreviewSnapshotResult
    ) async throws -> EmailPreviewSnapshotResult
}

@MainActor
final class EmailPreviewSnapshotRenderScheduler: EmailPreviewSnapshotRenderScheduling {
    static let shared = EmailPreviewSnapshotRenderScheduler(maxConcurrentRenders: 2)

    private final class ScheduledRender {
        let id = UUID()
        let request: EmailPreviewSnapshotRequest
        let operation: @MainActor () async throws -> EmailPreviewSnapshotResult
        var continuations: [UUID: CheckedContinuation<EmailPreviewSnapshotResult, Error>] = [:]
        var isRunning = false
        var task: Task<Void, Never>?

        init(
            request: EmailPreviewSnapshotRequest,
            operation: @escaping @MainActor () async throws -> EmailPreviewSnapshotResult
        ) {
            self.request = request
            self.operation = operation
        }
    }

    private let maxConcurrentRenders: Int
    private var runningCount = 0
    private var queue: [ScheduledRender] = []
    private var inFlightByCacheKey: [String: ScheduledRender] = [:]
    private var pendingWaiterIDs: Set<UUID> = []
    private var cancelledPendingWaiterIDs: Set<UUID> = []

    init(maxConcurrentRenders: Int) {
        self.maxConcurrentRenders = max(1, maxConcurrentRenders)
    }

    func render(
        request: EmailPreviewSnapshotRequest,
        operation: @escaping @MainActor () async throws -> EmailPreviewSnapshotResult
    ) async throws -> EmailPreviewSnapshotResult {
        try Task.checkCancellation()

        let waiterID = UUID()
        let cacheKey = request.cacheKey
        pendingWaiterIDs.insert(waiterID)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    request: request,
                    operation: operation,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self, cacheKey] in
                self?.cancelWaiter(id: waiterID, cacheKey: cacheKey)
            }
        }
    }

    private func enqueue(
        request: EmailPreviewSnapshotRequest,
        operation: @escaping @MainActor () async throws -> EmailPreviewSnapshotResult,
        waiterID: UUID,
        continuation: CheckedContinuation<EmailPreviewSnapshotResult, Error>
    ) {
        pendingWaiterIDs.remove(waiterID)

        let wasCancelledBeforeEnqueue = cancelledPendingWaiterIDs.remove(waiterID) != nil
        guard !Task.isCancelled,
              !wasCancelledBeforeEnqueue else {
            continuation.resume(throwing: CancellationError())
            return
        }

        if let existing = inFlightByCacheKey[request.cacheKey] {
            existing.continuations[waiterID] = continuation
            return
        }

        let work = ScheduledRender(request: request, operation: operation)
        work.continuations[waiterID] = continuation
        inFlightByCacheKey[request.cacheKey] = work
        queue.append(work)
        startAvailableWork()
    }

    private func startAvailableWork() {
        while runningCount < maxConcurrentRenders, !queue.isEmpty {
            let work = queue.removeFirst()
            guard !work.continuations.isEmpty else {
                removeInFlightReference(for: work)
                continue
            }

            work.isRunning = true
            runningCount += 1
            work.task = Task { @MainActor [weak self, work] in
                let result: Result<EmailPreviewSnapshotResult, Error>
                do {
                    try Task.checkCancellation()
                    let value = try await work.operation()
                    try Task.checkCancellation()
                    result = .success(value)
                } catch {
                    result = .failure(error)
                }

                self?.finish(work, result: result)
            }
        }
    }

    private func cancelWaiter(id waiterID: UUID, cacheKey: String) {
        if pendingWaiterIDs.remove(waiterID) != nil {
            cancelledPendingWaiterIDs.insert(waiterID)
            return
        }

        guard let work = inFlightByCacheKey[cacheKey],
              let continuation = work.continuations.removeValue(forKey: waiterID) else {
            return
        }

        continuation.resume(throwing: CancellationError())

        guard work.continuations.isEmpty else {
            return
        }

        if work.isRunning {
            removeInFlightReference(for: work)
            work.task?.cancel()
        } else {
            queue.removeAll { $0.id == work.id }
            removeInFlightReference(for: work)
        }
    }

    private func finish(
        _ work: ScheduledRender,
        result: Result<EmailPreviewSnapshotResult, Error>
    ) {
        guard work.isRunning else {
            return
        }

        work.isRunning = false
        runningCount = max(0, runningCount - 1)
        removeInFlightReference(for: work)

        let continuations = Array(work.continuations.values)
        work.continuations.removeAll()
        for continuation in continuations {
            continuation.resume(with: result)
        }

        startAvailableWork()
    }

    private func removeInFlightReference(for work: ScheduledRender) {
        let cacheKey = work.request.cacheKey
        if inFlightByCacheKey[cacheKey]?.id == work.id {
            inFlightByCacheKey.removeValue(forKey: cacheKey)
        }
    }
}

@MainActor
final class EmailPreviewSnapshotRenderer: EmailPreviewSnapshotRendering {
    static let shared = EmailPreviewSnapshotRenderer()

    private let scheduler: any EmailPreviewSnapshotRenderScheduling

    init(scheduler: any EmailPreviewSnapshotRenderScheduling = EmailPreviewSnapshotRenderScheduler.shared) {
        self.scheduler = scheduler
    }

    func render(request: EmailPreviewSnapshotRequest) async throws -> EmailPreviewSnapshotResult {
        try Task.checkCancellation()
        return try await scheduler.render(request: request) {
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
