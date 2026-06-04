import XCTest
@testable import esc_chatmail

@MainActor
final class OriginalEmailLoadViewModelTests: XCTestCase {
    func testLocalHTMLLoadsNormally() async throws {
        let html = "<html><body>Local original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .html,
                    sourceLocation: .messageFile
                )
            ]
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.5,
            recoveringDelay: 0.05
        )

        _ = await viewModel.loadOriginalEmail(for: makeRequest(messageId: "local-html"))

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testInitialLoadedHTMLStartsLoadedWithoutEnteringLoadingOrRecovering() async throws {
        let html = "<html><body>Prepared original</body></html>"
        let request = makeRequest(messageId: "prepared-html")
        let initialSource = originalEmailSource(
            presentation: .html,
            html: html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            sourceSignature: "prepared-source"
        )
        let loader = StubOriginalEmailSourceLoader(
            responses: [nil],
            delayNanoseconds: 80_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.03,
            recoveringDelay: 0.005,
            initialLoadedSource: initialSource,
            initialRequest: request
        )

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "prepared-source")

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: request,
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))

        _ = await task.value

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "prepared-source")
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testSlowEnsureTimesOutBeforeForegroundRecoveryCompletes() async throws {
        let loader = StubOriginalEmailSourceLoader(
            responses: [nil],
            delayNanoseconds: 80_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.03,
            recoveringDelay: 0.005
        )

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(for: makeRequest(messageId: "slow-missing"))
        }

        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)

        _ = await task.value

        XCTAssertEqual(viewModel.loadState, .retryableFailure("original_email_unavailable"))
        XCTAssertEqual(loader.ensureRequestCount, 1)
        XCTAssertEqual(loader.completedEnsureRequestCount, 0)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(loader.completedEnsureRequestCount, 1)
    }

    func testRetryableTimeoutAppliesLateSuccessfulSource() async throws {
        let html = "<html><body>Late local original</body></html>"
        let lateSource = originalEmailSource(
            presentation: .html,
            html: html,
            sourceKind: .html,
            sourceLocation: .messageFile
        )
        var acceptedSources: [OriginalEmailSource] = []
        let loader = ManuallyCompletingOriginalEmailSourceLoader(
            source: lateSource
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005,
            onSourceLoaded: { source in
                acceptedSources.append(source)
            }
        )

        let source = await viewModel.loadOriginalEmail(
            for: makeRequest(messageId: "late-success"),
            missingSourceRecoveryPolicy: .markUnavailableAfterRetries
        )

        XCTAssertNil(source)
        XCTAssertEqual(viewModel.loadState, .retryableFailure("original_email_unavailable"))
        XCTAssertEqual(loader.ensureRequestCount, 1)
        XCTAssertEqual(loader.completedEnsureRequestCount, 0)
        XCTAssertTrue(acceptedSources.isEmpty)

        loader.complete()
        try await waitForLoadState(.loaded(.html(html)), in: viewModel)

        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "html-signature")
        XCTAssertEqual(loader.completedEnsureRequestCount, 1)
        XCTAssertEqual(acceptedSources, [lateSource])
    }

    func testUnavailableStateIsRetryCapable() async {
        let loader = StubOriginalEmailSourceLoader(responses: [nil])
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        _ = await viewModel.loadOriginalEmail(for: makeRequest(messageId: "retry-missing"))
        XCTAssertEqual(viewModel.loadState, .retryableFailure("original_email_unavailable"))

        viewModel.retry()

        XCTAssertEqual(viewModel.loadState, .loading)
        XCTAssertEqual(viewModel.reloadGeneration, 1)
    }

    func testRetryCanLoadWarmedContentLater() async {
        let html = "<html><body>Warmed original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                nil,
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                )
            ]
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )
        let request = makeRequest(messageId: "warmed-retry")

        _ = await viewModel.loadOriginalEmail(for: request)
        XCTAssertEqual(viewModel.loadState, .retryableFailure("original_email_unavailable"))

        viewModel.retry()
        _ = await viewModel.loadOriginalEmail(for: request)

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.ensureRequestCount, 2)
    }

    func testPreservingReloadKeepsLoadedHTMLWhenRefreshReturnsNil() async {
        let html = "<html><body>Already visible original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .html,
                    sourceLocation: .messageFile
                ),
                nil
            ]
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )
        let request = makeRequest(messageId: "preserving-refresh")

        _ = await viewModel.loadOriginalEmail(for: request)
        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "html-signature")

        viewModel.reloadPreservingContent()
        _ = await viewModel.loadOriginalEmail(for: request)

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "html-signature")
        XCTAssertEqual(loader.ensureRequestCount, 2)
    }

    func testSuccessfulRecoveryRendersHTML() async throws {
        let html = "<html><body>Recovered original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                )
            ]
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.5,
            recoveringDelay: 0.005
        )

        _ = await viewModel.loadOriginalEmail(for: makeRequest(messageId: "recovered-html"))

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
    }

    func testDelayedForegroundRecoveryLoadsWarmedHTMLWithoutUnavailableState() async throws {
        let html = "<html><body>Auto-retried recovered original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                )
            ],
            delayNanoseconds: 40_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.1,
            recoveringDelay: 0.005
        )

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(for: makeRequest(messageId: "auto-retry-warmed"))
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)

        _ = await task.value

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testForegroundRecoveryStopsAtRetryableFailureForTrueMiss() async {
        let loader = StubOriginalEmailSourceLoader(responses: [nil, nil, nil])
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        _ = await viewModel.loadOriginalEmail(for: makeRequest(messageId: "auto-retry-missing"))

        XCTAssertEqual(viewModel.loadState, .retryableFailure("original_email_unavailable"))
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testPlaceholderBackedRecoveryWaitsUntilForegroundWarmIsVisible() async throws {
        let html = "<html><body>Background warmed original</body></html>"
        let loader = CacheWarmingOriginalEmailSourceLoader(
            warmedSource: originalEmailSource(
                presentation: .html,
                html: html,
                sourceKind: .html,
                sourceLocation: .messageFile
            ),
            warmDelayNanoseconds: 30_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.1,
            recoveringDelay: 0.005
        )

        _ = await viewModel.loadOriginalEmail(
            for: makeRequest(messageId: "placeholder-recovering-warmed"),
            missingSourceRecoveryPolicy: .keepRecoveringWhileActive
        )

        let requestCount = await loader.requestCount
        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(requestCount, 1)
    }

    func testPlaceholderBackedRecoveryContinuesAfterSoftTimeoutUntilWarmIsVisible() async throws {
        let html = "<html><body>Placeholder-backed recovered original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                )
            ],
            delayNanoseconds: 40_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: makeRequest(messageId: "placeholder-recovered-later"),
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)
        XCTAssertEqual(loader.ensureRequestCount, 1)
        XCTAssertEqual(loader.completedEnsureRequestCount, 0)

        _ = await task.value

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testFullReaderRecoveryContinuesAfterSoftTimeoutWithoutSnapshotPlaceholder() async throws {
        let html = "<html><body>No-snapshot recovered original</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                )
            ],
            delayNanoseconds: 40_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: makeRequest(messageId: "full-reader-no-snapshot-recovered-later"),
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)
        XCTAssertEqual(loader.ensureRequestCount, 1)
        XCTAssertEqual(loader.completedEnsureRequestCount, 0)

        _ = await task.value

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testPlaceholderBackedRecoveryStopsWaitingWhenCancelledAfterSoftTimeout() async throws {
        let loader = ManuallyCompletingOriginalEmailSourceLoader(
            source: originalEmailSource(
                presentation: .html,
                html: "<html><body>Slow placeholder recovery</body></html>",
                sourceKind: .recoveredHTML,
                sourceLocation: .recoveredHTML
            )
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: makeRequest(messageId: "placeholder-cancelled-recovery"),
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)
        XCTAssertEqual(loader.ensureRequestCount, 1)
        XCTAssertEqual(loader.completedEnsureRequestCount, 0)

        task.cancel()
        let cancelledResult = await withSoftTimeout(seconds: 0.25) {
            await task.value
        }

        guard case .some(.none) = cancelledResult else {
            XCTFail("Expected placeholder-backed recovery to return nil promptly after cancellation")
            loader.complete()
            _ = await task.value
            return
        }

        XCTAssertEqual(loader.completedEnsureRequestCount, 0)
        loader.complete()
    }

    func testPlaceholderBackedRecoveryCanRestartFromRecoveringAndLoadLaterHTML() async throws {
        let html = "<html><body>Notification restarted recovery</body></html>"
        let loader = StubOriginalEmailSourceLoader(
            responses: [
                nil,
                originalEmailSource(
                    presentation: .html,
                    html: html,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                )
            ],
            delayNanoseconds: 100_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.2,
            recoveringDelay: 0.005
        )
        let request = makeRequest(messageId: "placeholder-reload-from-recovering")

        let firstTask = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: request,
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)

        viewModel.reloadPreservingContent()
        firstTask.cancel()
        _ = await firstTask.value

        _ = await viewModel.loadOriginalEmail(
            for: request,
            missingSourceRecoveryPolicy: .keepRecoveringWhileActive
        )

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.reloadGeneration, 1)
        XCTAssertEqual(loader.ensureRequestCount, 2)
    }

    func testContentSourceReloadPolicyReloadsWhileSourceIsResolving() {
        let resolvingStates: [OriginalEmailLoadState] = [.loading, .recovering]

        for loadState in resolvingStates {
            XCTAssertTrue(
                OriginalEmailContentSourceReloadPolicy.shouldReload(
                    changedMessageId: "message-1",
                    currentMessageId: "message-1",
                    changedSourceSignature: "new-source",
                    activeSourceSignature: nil,
                    loadState: loadState
                )
            )
        }
    }

    func testContentSourceReloadPolicySkipsAlreadyLoadedSourceSignature() {
        XCTAssertFalse(
            OriginalEmailContentSourceReloadPolicy.shouldReload(
                changedMessageId: "message-1",
                currentMessageId: "message-1",
                changedSourceSignature: "loaded-source",
                activeSourceSignature: "loaded-source",
                loadState: .loaded(.html("<html></html>"))
            )
        )
    }

    func testContentSourceReloadDuringRecoverySupersedesStaleInFlightLoad() async throws {
        let staleHTML = "<html><body>Stale original</body></html>"
        let freshHTML = "<html><body>Fresh synced original</body></html>"
        let staleSource = originalEmailSource(
            presentation: .html,
            html: staleHTML,
            sourceKind: .html,
            sourceLocation: .messageFile,
            sourceSignature: "old-source"
        )
        let freshSource = originalEmailSource(
            presentation: .html,
            html: freshHTML,
            sourceKind: .html,
            sourceLocation: .messageFile,
            sourceSignature: "new-source"
        )
        let loader = BodyTextCompletingOriginalEmailSourceLoader()
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )
        let staleRequest = makeRequest(
            messageId: "content-source-reload",
            bodyText: "Old raw source"
        )
        let freshRequest = makeRequest(
            messageId: "content-source-reload",
            bodyText: "Fresh synced raw source"
        )

        let staleTask = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: staleRequest,
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await waitForEnsureRequestCount(1, in: loader)
        try await waitForLoadState(.recovering, in: viewModel)

        viewModel.reloadPreservingContent()
        let freshTask = Task { @MainActor in
            await viewModel.loadOriginalEmail(
                for: freshRequest,
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await waitForEnsureRequestCount(2, in: loader)
        XCTAssertTrue(loader.completeRequest(bodyText: "Fresh synced raw source", with: freshSource))

        let freshResult = await freshTask.value
        XCTAssertEqual(freshResult, freshSource)
        XCTAssertEqual(viewModel.loadState, .loaded(.html(freshHTML)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "new-source")

        XCTAssertTrue(loader.completeRequest(bodyText: "Old raw source", with: staleSource))
        let staleResult = await staleTask.value
        XCTAssertNil(staleResult)
        XCTAssertEqual(viewModel.loadState, .loaded(.html(freshHTML)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "new-source")
    }

    private func makeRequest(
        messageId: String,
        bodyText: String = "Plain fallback"
    ) -> OriginalEmailLoadRequest {
        OriginalEmailLoadRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: bodyText,
            subject: "Original",
            senderEmail: "sender@example.com"
        )
    }

    private func originalEmailSource(
        presentation: OriginalEmailSource.Presentation,
        html: String?,
        plainText: String? = nil,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        sourceSignature: String? = nil
    ) -> OriginalEmailSource {
        OriginalEmailSource(
            presentation: presentation,
            html: html,
            plainText: plainText,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            sourceSignature: sourceSignature ?? "\(sourceKind.rawValue)-signature",
            hasHTMLSource: html != nil
        )
    }

    private func waitForEnsureRequestCount(
        _ expectedCount: Int,
        in loader: BodyTextCompletingOriginalEmailSourceLoader,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while loader.ensureRequestCount < expectedCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(loader.ensureRequestCount, expectedCount, file: file, line: line)
    }

    private func waitForLoadState(
        _ expectedState: OriginalEmailLoadState,
        in viewModel: OriginalEmailLoadViewModel,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.loadState != expectedState, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(viewModel.loadState, expectedState, file: file, line: line)
    }
}

private final class BodyTextCompletingOriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    private struct PendingRequest {
        let bodyText: String?
        let continuation: CheckedContinuation<OriginalEmailSource?, Never>
    }

    private let stateQueue = DispatchQueue(label: "BodyTextCompletingOriginalEmailSourceLoader.state")
    private var pendingRequests: [PendingRequest] = []
    private var ensureCalls = 0

    var ensureRequestCount: Int {
        stateQueue.sync { ensureCalls }
    }

    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        await ensureOriginalEmailAvailable(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    func ensureOriginalEmailAvailable(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText: String?,
        senderEmail _: String?,
        subject _: String?
    ) async -> OriginalEmailSource? {
        await withCheckedContinuation { continuation in
            stateQueue.sync {
                ensureCalls += 1
                pendingRequests.append(
                    PendingRequest(
                        bodyText: bodyText,
                        continuation: continuation
                    )
                )
            }
        }
    }

    func completeRequest(bodyText: String?, with source: OriginalEmailSource?) -> Bool {
        let continuation = stateQueue.sync { () -> CheckedContinuation<OriginalEmailSource?, Never>? in
            guard let index = pendingRequests.firstIndex(where: { $0.bodyText == bodyText }) else {
                return nil
            }
            return pendingRequests.remove(at: index).continuation
        }

        continuation?.resume(returning: source)
        return continuation != nil
    }
}

private final class StubOriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "StubOriginalEmailSourceLoader.state")
    private var responses: [OriginalEmailSource?]
    private let delayNanoseconds: UInt64
    private var timeouts: [TimeInterval] = []
    private var ensureCalls = 0
    private var completedEnsureCalls = 0

    init(responses: [OriginalEmailSource?], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    var observedTimeouts: [TimeInterval] {
        stateQueue.sync { timeouts }
    }

    var requestCount: Int {
        stateQueue.sync { timeouts.count + ensureCalls }
    }

    var ensureRequestCount: Int {
        stateQueue.sync { ensureCalls }
    }

    var completedEnsureRequestCount: Int {
        stateQueue.sync { completedEnsureCalls }
    }

    func loadOriginalEmailSource(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        await nextResponse(recordedTimeout: timeout)
    }

    func ensureOriginalEmailAvailable(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?
    ) async -> OriginalEmailSource? {
        await nextResponse(recordedTimeout: nil)
    }

    private func nextResponse(recordedTimeout timeout: TimeInterval?) async -> OriginalEmailSource? {
        let isEnsureRequest = timeout == nil
        let response = stateQueue.sync {
            if let timeout {
                timeouts.append(timeout)
            } else {
                ensureCalls += 1
            }
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        if isEnsureRequest {
            stateQueue.sync {
                completedEnsureCalls += 1
            }
        }

        return response
    }
}

private final class ManuallyCompletingOriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "ManuallyCompletingOriginalEmailSourceLoader.state")
    private let source: OriginalEmailSource?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isComplete = false
    private var ensureCalls = 0
    private var completedEnsureCalls = 0

    init(source: OriginalEmailSource?) {
        self.source = source
    }

    var ensureRequestCount: Int {
        stateQueue.sync { ensureCalls }
    }

    var completedEnsureRequestCount: Int {
        stateQueue.sync { completedEnsureCalls }
    }

    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        await ensureOriginalEmailAvailable(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    func ensureOriginalEmailAvailable(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?
    ) async -> OriginalEmailSource? {
        stateQueue.sync {
            ensureCalls += 1
        }

        await waitForCompletion()

        stateQueue.sync {
            completedEnsureCalls += 1
        }
        return source
    }

    func complete() {
        let continuation = stateQueue.sync { () -> CheckedContinuation<Void, Never>? in
            isComplete = true
            let continuation = releaseContinuation
            releaseContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func waitForCompletion() async {
        let alreadyComplete = stateQueue.sync { isComplete }
        if alreadyComplete {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = stateQueue.sync { () -> Bool in
                if isComplete {
                    return true
                }
                releaseContinuation = continuation
                return false
            }

            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private actor CacheWarmingOriginalEmailSourceLoader: OriginalEmailSourceLoading {
    private let warmedSource: OriginalEmailSource
    private let warmDelayNanoseconds: UInt64
    private var timeouts: [TimeInterval] = []
    private var ensureCalls = 0
    private var cachedSource: OriginalEmailSource?
    private var hasStartedWarm = false

    init(warmedSource: OriginalEmailSource, warmDelayNanoseconds: UInt64) {
        self.warmedSource = warmedSource
        self.warmDelayNanoseconds = warmDelayNanoseconds
    }

    var requestCount: Int {
        timeouts.count + ensureCalls
    }

    var observedTimeouts: [TimeInterval] {
        timeouts
    }

    func loadOriginalEmailSource(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        timeouts.append(timeout)
        let source = cachedSource
        let shouldStartWarm = cachedSource == nil && !hasStartedWarm
        if shouldStartWarm {
            hasStartedWarm = true
        }

        if let source {
            return source
        }

        if shouldStartWarm {
            Task { [self] in
                if warmDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: warmDelayNanoseconds)
                }
                storeWarmedSource()
            }
        }

        if timeout > 0 {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }

        return cachedSource
    }

    func ensureOriginalEmailAvailable(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?
    ) async -> OriginalEmailSource? {
        ensureCalls += 1
        if let cachedSource {
            return cachedSource
        }

        if warmDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: warmDelayNanoseconds)
        }
        cachedSource = warmedSource
        return cachedSource
    }

    private func storeWarmedSource() {
        cachedSource = warmedSource
    }
}
