import Foundation

/// Serves a scripted sequence of responses; the last entry repeats once the
/// script is exhausted. State is static (URLProtocol instances are created by
/// the URL loading system) and lock-guarded.
///
/// Shared by API-client tests that need real URLSession behavior (retry
/// loops, status-code mapping) without the network. Reset in setUp/tearDown.
final class StubURLProtocol: URLProtocol {
    enum Response {
        case status(Int)
        case data(Int, Data)
        case dataWithHeaders(Int, Data, [String: String])
        case error(URLError)
    }

    private static let lock = NSLock()
    private static var _script: [Response] = []
    private static var _requestCount = 0
    private static var _requestURLs: [URL] = []
    private static var _requests: [URLRequest] = []
    private static var _onStartLoading: (@Sendable (URLRequest) -> Void)?
    private static var _responder: (@Sendable (URLRequest) -> Response)?

    /// Answers each request at the moment it arrives, in place of `script`:
    /// for a response that depends on when it is asked (a rate limit that
    /// ends at a time on a `FakeSyncClock`).
    static var responder: (@Sendable (URLRequest) -> Response)? {
        get { lock.withLock { _responder } }
        set { lock.withLock { _responder = newValue } }
    }

    static var script: [Response] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    static var requestCount: Int {
        lock.withLock { _requestCount }
    }

    /// URLs of every request served, in arrival order — lets tests pin query
    /// items on real client-built requests.
    static var requestURLs: [URL] {
        lock.withLock { _requestURLs }
    }

    /// Every request served, in arrival order, as the loading system handed it
    /// over (method and headers; an upload's body is not in it).
    static var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    /// Called with each request as it starts loading, before it is answered:
    /// lets a test look at what exists at that moment (an upload's file) and
    /// read an upload's body from `httpBodyStream`.
    static var onStartLoading: (@Sendable (URLRequest) -> Void)? {
        get { lock.withLock { _onStartLoading } }
        set { lock.withLock { _onStartLoading = newValue } }
    }

    static func reset() {
        lock.withLock {
            _onStartLoading = nil
            _script = []
            _requestCount = 0
            _requestURLs = []
            _requests = []
            _responder = nil
        }
    }

    /// Convenience: a URLSession routed through this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func nextResponse(for request: URLRequest) -> Response? {
        let responder: (@Sendable (URLRequest) -> Response)? = lock.withLock {
            _requestCount += 1
            _requests.append(request)
            if let url = request.url {
                _requestURLs.append(url)
            }
            return _responder
        }
        if let responder {
            return responder(request)
        }
        return lock.withLock {
            guard !_script.isEmpty else { return nil }
            return _script.count > 1 ? _script.removeFirst() : _script[0]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStartLoading?(request)
        guard let url = request.url, let response = Self.nextResponse(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch response {
        case .status(let code):
            send(url: url, statusCode: code, body: Data(), headers: [:])
        case .data(let code, let body):
            send(url: url, statusCode: code, body: body, headers: [:])
        case .dataWithHeaders(let code, let body, let headers):
            send(url: url, statusCode: code, body: body, headers: headers)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func send(url: URL, statusCode: Int, body: Data, headers: [String: String]) {
        var headerFields = ["Content-Type": "application/json"]
        for (key, value) in headers {
            headerFields[key] = value
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
