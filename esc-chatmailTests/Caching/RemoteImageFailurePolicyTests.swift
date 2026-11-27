import XCTest
@testable import esc_chatmail

/// `RemoteImageFailurePolicy` is the one definition of which failures of a remote image
/// fetch are the URL's for good and which are for now (architecture review 2026-11,
/// networking#6, caching-memory#2).
final class RemoteImageFailurePolicyTests: XCTestCase {
    private struct UnknownError: Error {}

    // Revert-check: fails if a definitive failure is classified transient (a refused URL
    // would be fetched again every 30 s) or a transient one definitive (an offline view
    // would blacklist the URL for the process).
    func testClassification_table() {
        let definitive: [Error] = [
            RemoteImageFetchError.invalidURL,
            RemoteImageFetchError.privateOrReservedHost,
            RemoteImageFetchError.unsupportedContentType("text/html"),
            RemoteImageFetchError.responseTooLarge(9_000_000),
            RemoteImageFetchError.undecodableImage,
            RemoteImageFetchError.invalidStatusCode(301),
            RemoteImageFetchError.invalidStatusCode(302),
            RemoteImageFetchError.invalidStatusCode(403),
            RemoteImageFetchError.invalidStatusCode(404),
            RemoteImageFetchError.invalidStatusCode(410)
        ]
        for error in definitive {
            XCTAssertTrue(RemoteImageFailurePolicy.isDefinitive(error), "\(error)")
            guard case .definitiveFailure = RemoteImageFailurePolicy.outcome(for: error) else {
                return XCTFail("Expected definitiveFailure for \(error)")
            }
        }

        let transient: [Error] = [
            RemoteImageFetchError.invalidStatusCode(408),
            RemoteImageFetchError.invalidStatusCode(429),
            RemoteImageFetchError.invalidStatusCode(500),
            RemoteImageFetchError.invalidStatusCode(503),
            RemoteImageFetchError.invalidStatusCode(-1),
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            CancellationError(),
            UnknownError()
        ]
        for error in transient {
            XCTAssertFalse(RemoteImageFailurePolicy.isDefinitive(error), "\(error)")
            guard case .transientFailure = RemoteImageFailurePolicy.outcome(for: error) else {
                return XCTFail("Expected transientFailure for \(error)")
            }
        }
    }

    // Revert-check: fails if `EnhancedImageCache.clearAll()` stops forgetting the failed
    // URLs, which until 2026-11-27 nothing cleared. Pinned from source: the cache's
    // request manager is its own and the shared caches are not touched in tests.
    func testEnhancedImageCacheClearAll_forgetsTheFailedURLs() throws {
        let source = try repositorySource("esc-chatmail/Services/Caching/EnhancedImageCache.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let clearAll = try XCTUnwrap(source.range(of: "func clearAll() async {"))
        let body = source[clearAll.upperBound...]
        let end = try XCTUnwrap(body.range(of: "\n    }"))
        XCTAssertTrue(body[..<end.lowerBound].contains("requestManager.clearFailedURLs()"))
    }
}
