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

    static var script: [Response] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    static var requestCount: Int {
        lock.withLock { _requestCount }
    }

    static func reset() {
        lock.withLock {
            _script = []
            _requestCount = 0
        }
    }

    /// Convenience: a URLSession routed through this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func nextResponse() -> Response? {
        lock.withLock {
            _requestCount += 1
            guard !_script.isEmpty else { return nil }
            return _script.count > 1 ? _script.removeFirst() : _script[0]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.nextResponse() else {
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
