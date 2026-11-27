import Foundation

/// Which failures of a remote image fetch are the URL's for good and which are for now:
/// the one definition `RemoteImageFetcher` answers with and `ImageRequestManager`
/// remembers by (architecture review 2026-11, networking#6, caching-memory#2).
enum RemoteImageFailurePolicy {
    static func outcome(for error: Error) -> RemoteImageFetchOutcome {
        isDefinitive(error) ? .definitiveFailure : .transientFailure
    }

    /// Definitive: the URL itself is refused (invalid, a private or reserved host), the
    /// server answered 3xx (the guarding session refuses redirects to private addresses
    /// and hands the 3xx back) or a 4xx that is not 408 or 429, the type is not an image,
    /// the body is past the limit, or the bytes do not decode. Transient: a transport
    /// error (offline, a timeout, cancellation), a 5xx, a 408 or a 429, a response that
    /// was not HTTP, and anything this policy does not know, because a failure it cannot
    /// name must not blacklist a URL for the process.
    static func isDefinitive(_ error: Error) -> Bool {
        guard let fetchError = error as? RemoteImageFetchError else {
            return false
        }
        switch fetchError {
        case .invalidURL, .privateOrReservedHost, .unsupportedContentType, .responseTooLarge, .undecodableImage:
            return true
        case .invalidStatusCode(let statusCode):
            if (300...399).contains(statusCode) {
                return true
            }
            if (400...499).contains(statusCode) {
                return statusCode != 408 && statusCode != 429
            }
            return false
        }
    }
}
