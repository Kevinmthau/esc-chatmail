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

        await viewModel.loadOriginalEmail(for: makeRequest(messageId: "local-html"))

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.observedTimeouts, [0.5])
    }

    func testSlowUnavailableLoadExitsRecoveringState() async throws {
        let loader = StubOriginalEmailSourceLoader(
            responses: [nil],
            delayNanoseconds: 50_000_000
        )
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        let task = Task { @MainActor in
            await viewModel.loadOriginalEmail(for: makeRequest(messageId: "slow-missing"))
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(viewModel.loadState, .recovering)

        await task.value

        XCTAssertEqual(viewModel.loadState, .unavailable)
        XCTAssertEqual(loader.observedTimeouts, [0.01])
    }

    func testUnavailableStateIsRetryCapable() async {
        let loader = StubOriginalEmailSourceLoader(responses: [nil])
        let viewModel = OriginalEmailLoadViewModel(
            originalEmailSourceLoader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        await viewModel.loadOriginalEmail(for: makeRequest(messageId: "retry-missing"))
        XCTAssertEqual(viewModel.loadState, .unavailable)

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

        await viewModel.loadOriginalEmail(for: request)
        XCTAssertEqual(viewModel.loadState, .unavailable)

        viewModel.retry()
        await viewModel.loadOriginalEmail(for: request)

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(loader.requestCount, 2)
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

        await viewModel.loadOriginalEmail(for: request)
        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "html-signature")

        viewModel.reloadPreservingContent()
        await viewModel.loadOriginalEmail(for: request)

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
        XCTAssertEqual(viewModel.activeHTMLSourceSignature, "html-signature")
        XCTAssertEqual(loader.requestCount, 2)
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

        await viewModel.loadOriginalEmail(for: makeRequest(messageId: "recovered-html"))

        XCTAssertEqual(viewModel.loadState, .loaded(.html(html)))
    }

    private func makeRequest(messageId: String) -> OriginalEmailLoadRequest {
        OriginalEmailLoadRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Plain fallback",
            subject: "Original",
            senderEmail: "sender@example.com"
        )
    }

    private func originalEmailSource(
        presentation: OriginalEmailSource.Presentation,
        html: String?,
        plainText: String? = nil,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation
    ) -> OriginalEmailSource {
        OriginalEmailSource(
            presentation: presentation,
            html: html,
            plainText: plainText,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            sourceSignature: "\(sourceKind.rawValue)-signature",
            hasHTMLSource: html != nil
        )
    }
}

private final class StubOriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [OriginalEmailSource?]
    private let delayNanoseconds: UInt64
    private var timeouts: [TimeInterval] = []

    init(responses: [OriginalEmailSource?], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    var observedTimeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timeouts
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return timeouts.count
    }

    func loadOriginalEmailSource(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?,
        isDarkMode _: Bool,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        lock.lock()
        timeouts.append(timeout)
        let response = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        return response
    }
}
