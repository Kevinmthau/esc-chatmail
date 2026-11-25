import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol RemoteImageFetching: Sendable {
    func image(from urlString: String) async -> PlatformImage?
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

    func image(from urlString: String) async -> PlatformImage? {
        guard await remoteConfig.isEnabled(.remoteImageLoadingEnabled) else {
            return nil
        }

        do {
            let data = try await imageData(from: urlString)
            try Task.checkCancellation()
            guard let image = await Self.decodedImage(from: data) else {
                throw RemoteImageFetchError.undecodableImage
            }
            return image
        } catch {
            logFetchFailure(error, urlString: urlString)
            return nil
        }
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
