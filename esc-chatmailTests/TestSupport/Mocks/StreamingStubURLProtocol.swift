import Foundation

/// Answers a `URLSession`'s requests from a script for each URL, delivering the body a chunk
/// at a time, for tests of code that reads a response as it arrives
/// (`SSRFGuardingURLSession.boundedData`). `StubURLProtocol` hands a body over whole and
/// cannot say whether its reader stopped early; this one records, for each URL, that a load
/// was started and that it was stopped.
///
/// Scripts are kept by URL in one process-wide table, so a test gives each of its URLs a
/// name of its own (`uniqueURL`) and takes its scripts out again (`removeScripts(for:)`).
final class StreamingStubURLProtocol: URLProtocol {
    struct Script: Sendable {
        var statusCode = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Whether the load ends after its last chunk. A load that never ends is how a test
        /// shows that its reader did not wait for the whole body: with nothing more to come,
        /// only a reader that has already decided returns. Give such a script a first chunk
        /// of `sniffedByteCount` bytes or more: `URLSession.bytes(for:)` hands a response
        /// over with the first bytes of its body, and for an image type or no type at all
        /// only once 512 of them are there, so a load with less answers nobody until the
        /// request times out.
        var finishes = true
        /// Answer with a redirect to this URL instead of a response of its own.
        var redirect: URL?
    }

    /// The bytes of a body the loading system holds a response back for while it works out
    /// the content's type (measured: 512 for `image/png` and for no `Content-Type`).
    static let sniffedByteCount = 512

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [URL: Script] = [:]
    nonisolated(unsafe) private static var startedURLs: [URL] = []
    nonisolated(unsafe) private static var stoppedURLs: [URL] = []

    /// Guarded by `stateLock`: `startLoading` and `stopLoading` can run on different threads.
    private let stateLock = NSLock()
    private var isStopped = false

    static func uniqueURL(host: String = "images.example.com", path: String = "picture") -> URL {
        URL(string: "https://\(host)/\(path)-\(UUID().uuidString)")!
    }

    static func setScript(_ script: Script, for url: URL) {
        lock.withLock { scripts[url] = script }
    }

    static func removeScripts(for urls: [URL]) {
        lock.withLock {
            for url in urls {
                scripts[url] = nil
            }
            startedURLs.removeAll { urls.contains($0) }
            stoppedURLs.removeAll { urls.contains($0) }
        }
    }

    /// Whether a load of `url` was started: whether the session asked for it at all.
    static func didStartLoading(_ url: URL) -> Bool {
        lock.withLock { startedURLs.contains(url) }
    }

    /// Whether a load of `url` was stopped, which is what the session does to a transfer its
    /// task cancelled, and also to one that finished.
    static func didStopLoading(_ url: URL) -> Bool {
        lock.withLock { stoppedURLs.contains(url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let script: Script? = Self.lock.withLock {
            Self.startedURLs.append(url)
            return Self.scripts[url]
        }
        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        if let redirect = script.redirect {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            // The redirect response has no body of its own. Where the session follows the
            // redirect it starts another load for the new URL; where its delegate refuses,
            // this is the whole answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: script.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: script.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks {
            if stateLock.withLock({ isStopped }) { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
        if script.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.withLock { isStopped = true }
        guard let url = request.url else { return }
        Self.lock.withLock { Self.stoppedURLs.append(url) }
    }
}
