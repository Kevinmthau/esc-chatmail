import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol RemoteImageFetching: Sendable {
    /// One fetch of a sender's image, with what its failure means for the caller's
    /// memory of failed URLs (`ImageRequestManager`).
    func fetchImage(from urlString: String) async -> RemoteImageFetchOutcome
}

/// What one fetch of a sender's image came to. The two failures are told apart because
/// `ImageRequestManager` remembered every failure for the process: one offline or
/// timed-out view left a card's hero image or a Drive thumbnail a placeholder until the
/// process ended, days on the Mac (architecture review 2026-11, networking#6,
/// caching-memory#2). `RemoteImageFailurePolicy` is the one definition of which is which.
enum RemoteImageFetchOutcome {
    case image(PlatformImage)
    /// The URL will not yield an image: an invalid or private URL, a 3xx (a redirect the
    /// guarding session refused), a 4xx other than 408 and 429, an unsupported type, a
    /// body past the limit, bytes that do not decode. Remembered for the process.
    case definitiveFailure
    /// The fetch failed for now: a transport error (offline, a timeout, cancellation), a
    /// 5xx, a 408 or a 429, or a response that was not HTTP. Remembered briefly.
    case transientFailure
    /// Remote image loading is switched off: nothing is remembered.
    case disabled
}

enum RemoteImageFetchError: Error, Equatable {
    case invalidURL
    case privateOrReservedHost
    case invalidStatusCode(Int)
    case unsupportedContentType(String?)
    /// The body is larger than the fetcher takes: the length the response declared, or,
    /// where it declared none, the limit the body ran past as it arrived.
    case responseTooLarge(Int64)
    /// The bytes are not an image the app will decode: not an image at all, one whose header
    /// names no size, or one past `ImageDownsampler`'s source-pixel budget.
    case undecodableImage
}

actor RemoteImageFetcher: RemoteImageFetching {
    static let shared = RemoteImageFetcher()

    private let session: URLSession
    private let maxImageBytes: Int
    private let timeoutInterval: TimeInterval
    private let remoteConfig: any RemoteConfigProvider

    init(
        session: URLSession = SSRFGuardingURLSession.shared,
        maxImageBytes: Int = 8 * 1024 * 1024,
        timeoutInterval: TimeInterval = 15,
        remoteConfig: any RemoteConfigProvider = StaticRemoteConfigProvider.shared
    ) {
        self.session = session
        self.maxImageBytes = maxImageBytes
        self.timeoutInterval = timeoutInterval
        self.remoteConfig = remoteConfig
    }

    func fetchImage(from urlString: String) async -> RemoteImageFetchOutcome {
        guard await remoteConfig.isEnabled(.remoteImageLoadingEnabled) else {
            return .disabled
        }

        do {
            let data = try await imageData(from: urlString)
            try Task.checkCancellation()
            guard let image = await Self.decodedImage(from: data) else {
                throw RemoteImageFetchError.undecodableImage
            }
            return .image(image)
        } catch {
            logFetchFailure(error, urlString: urlString)
            return RemoteImageFailurePolicy.outcome(for: error)
        }
    }

    /// The image or nil, for a caller that remembers nothing of a failure
    /// (`ProfilePhotoResolver`).
    func image(from urlString: String) async -> PlatformImage? {
        if case .image(let image) = await fetchImage(from: urlString) {
            return image
        }
        return nil
    }

    func imageData(from urlString: String) async throws -> Data {
        let url = try validatedURL(from: urlString)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .returnCacheDataElseLoad
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

        // The status, the content type and a declared length are refused on the response's
        // headers, as its body begins to arrive, and an undeclared body is given up at the
        // limit. With `data(for:)` all four were checked on a body already downloaded whole.
        do {
            let (data, _) = try await SSRFGuardingURLSession.boundedData(
                for: request,
                maxBytes: maxImageBytes,
                session: session,
                acceptResponse: { response in try RemoteImageFetcher.acceptImageResponse(response) }
            )
            return data
        } catch let tooLarge as SSRFGuardingURLSession.ResponseTooLarge {
            throw RemoteImageFetchError.responseTooLarge(
                tooLarge.declaredByteCount ?? Int64(tooLarge.maxBytes)
            )
        }
    }

    /// The image the fetched bytes hold, at no more than the cache's pixel cap, or nil where
    /// `ImageDownsampler` refuses them. `PlatformImage(data:)` here took whatever size the
    /// sender's header named, and the disk cache then decoded all of it to re-encode it.
    ///
    /// A static async function is not the actor's, so the decode runs off it and a large image
    /// does not hold up the other fetches' turns on it for as long as it decodes.
    private static func decodedImage(from data: Data) async -> PlatformImage? {
        ImageDownsampler.decode(data: data)
    }

    /// What `imageData` refuses on a response's headers, with none of its body kept.
    private static func acceptImageResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteImageFetchError.invalidStatusCode(-1)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw RemoteImageFetchError.invalidStatusCode(httpResponse.statusCode)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        if let contentType, !isSupportedImageContentType(contentType) {
            throw RemoteImageFetchError.unsupportedContentType(contentType)
        }
    }

    private func validatedURL(from urlString: String) throws -> URL {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            throw RemoteImageFetchError.invalidURL
        }

        guard !PrivateNetworkAddressDetector.isPrivateOrReserved(url) else {
            throw RemoteImageFetchError.privateOrReservedHost
        }

        return url
    }

    private static func isSupportedImageContentType(_ contentType: String) -> Bool {
        let normalized = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        return normalized.hasPrefix("image/") || normalized == "application/octet-stream"
    }

    private nonisolated func logFetchFailure(_ error: Error, urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled,
              nsError.code != NSURLErrorTimedOut,
              nsError.code != NSURLErrorNotConnectedToInternet else {
            return
        }

        Log.debug(
            "Remote image load failed for \(Log.redact(url: url)): \(Log.redact(error: error))",
            category: .general
        )
    }
}
