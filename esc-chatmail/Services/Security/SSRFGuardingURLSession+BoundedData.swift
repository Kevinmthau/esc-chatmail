import Foundation

extension SSRFGuardingURLSession {
    /// A response whose body is larger than its caller will take. Thrown with none of the
    /// body kept when the response declares its length, and otherwise as soon as the body
    /// has run past the limit.
    struct ResponseTooLarge: Error, Equatable {
        /// The length the response declared, or nil where it declared none (or a smaller one)
        /// and the body ran past the limit as it arrived.
        let declaredByteCount: Int64?
        let maxBytes: Int
    }

    /// Loads `request` and returns its body, never holding more than `maxBytes` of it.
    ///
    /// The URL is a sender's (architecture review 2026-11, `security-privacy#1` and
    /// `networking#6`). `URLSession.data(for:)` hands back a body only once all of it is in
    /// memory, so a limit checked on its result is checked after the download: a response of
    /// any size was buffered whole, for as long as the session's resource timeout allowed,
    /// and a declared `Content-Length` past the limit was downloaded all the same. This reads
    /// the body as it arrives (`bytes(for:)`) and stops at the limit.
    ///
    /// Three things are decided on the response's headers, before this takes a byte of the
    /// body: whatever `acceptResponse` throws for (a status, a content type), and a declared
    /// length past `maxBytes`. Every refusal, and the caller's own cancellation, cancels the
    /// transfer. "Before the body" is not "before the body starts": `bytes(for:)` hands the
    /// response over with the body's first bytes, not ahead of them, and for a type the
    /// loading system sniffs (`image/png`, or no `Content-Type` at all) only once 512 of
    /// them are there; `text/html` and `application/octet-stream` were handed over at once.
    /// Measured on macOS 27.2 against a local server that sent its headers, some bytes, and
    /// nothing more. So a response is refused as its body begins to arrive, and one whose
    /// body stalls short of that waits for the request's timeout, whatever its headers say.
    ///
    /// It stays on a session the caller names, `shared` by default, and never makes one of
    /// its own: the redirect guard and the absent cookie store are the session's, and a
    /// second session built to receive bytes would have neither.
    /// `SSRFBoundedDataTests` runs a redirect to a private address through this function on a
    /// session made as `shared` is.
    ///
    /// - Parameter acceptResponse: throws to refuse the response on its headers alone.
    static func boundedData(
        for request: URLRequest,
        maxBytes: Int,
        session: URLSession = shared,
        acceptResponse: @Sendable (URLResponse) throws -> Void = { _ in }
    ) async throws -> (Data, URLResponse) {
        let maxBytes = max(0, maxBytes)
        let (bytes, response) = try await session.bytes(for: request)
        do {
            try acceptResponse(response)

            // -1 where the response declares no length.
            let declaredByteCount = response.expectedContentLength
            if declaredByteCount > Int64(maxBytes) {
                throw ResponseTooLarge(declaredByteCount: declaredByteCount, maxBytes: maxBytes)
            }

            var body: [UInt8] = []
            for try await byte in bytes {
                guard body.count < maxBytes else {
                    throw ResponseTooLarge(
                        declaredByteCount: declaredByteCount >= 0 ? declaredByteCount : nil,
                        maxBytes: maxBytes
                    )
                }
                // Reserved at the first byte, not on the headers: a HEAD's response declares
                // the length of a body it does not have.
                if body.isEmpty, declaredByteCount > 0 {
                    body.reserveCapacity(Int(declaredByteCount))
                }
                body.append(byte)
            }
            return (Data(body), response)
        } catch {
            // The body this just declined must stop arriving. Letting go of `bytes` ended
            // the transfer by itself where it was tried (iOS 27.0 simulator, a `URLProtocol`
            // stub), so this says outright what nothing documents.
            bytes.task.cancel()
            throw error
        }
    }
}
