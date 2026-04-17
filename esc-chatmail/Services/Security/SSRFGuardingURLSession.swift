import Foundation

/// A `URLSession` hardened for fetches whose URLs come from untrusted email
/// content. Differences from `URLSession.shared`:
///
/// - Blocks HTTP redirects whose target is a private / loopback / link-local
///   / reserved address (defense against redirect-based SSRF where the
///   initial hostname looks public but redirects to an internal service).
/// - Disables cookie storage so a fetch to an attacker's host cannot read or
///   write the shared cookie jar.
/// - Applies conservative per-request / per-resource timeouts.
///
/// Callers should still do a pre-fetch check with
/// `PrivateNetworkAddressDetector.isPrivateOrReserved(_:)` on the initial URL
/// — the redirect delegate only sees URLs reached via redirection.
enum SSRFGuardingURLSession {
    static let shared: URLSession = makeSession()

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        // HTTP/3 opt-out is set per-request by callers when they need it.

        return URLSession(
            configuration: configuration,
            delegate: RedirectGuard(),
            delegateQueue: nil
        )
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                completionHandler(nil)
                return
            }

            if PrivateNetworkAddressDetector.isPrivateOrReserved(url) {
                Log.warning(
                    "SSRFGuardingURLSession blocked redirect to private host \(url.host ?? "<nil>")",
                    category: .general
                )
                completionHandler(nil)
                return
            }

            completionHandler(request)
        }
    }
}
