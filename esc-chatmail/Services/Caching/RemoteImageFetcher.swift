import Foundation
import UIKit

protocol RemoteImageFetching: Sendable {
    func image(from urlString: String) async -> UIImage?
}

enum RemoteImageFetchError: Error, Equatable {
    case invalidURL
    case privateOrReservedHost
    case invalidStatusCode(Int)
    case unsupportedContentType(String?)
    case responseTooLarge(Int64)
    case decodedImageTooLarge(Int)
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

    func image(from urlString: String) async -> UIImage? {
        guard await remoteConfig.isEnabled(.remoteImageLoadingEnabled) else {
            return nil
        }

        do {
            let data = try await imageData(from: urlString)
            guard let image = UIImage(data: data) else {
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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteImageFetchError.invalidStatusCode(-1)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw RemoteImageFetchError.invalidStatusCode(httpResponse.statusCode)
        }

        if httpResponse.expectedContentLength > Int64(maxImageBytes) {
            throw RemoteImageFetchError.responseTooLarge(httpResponse.expectedContentLength)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        if let contentType, !Self.isSupportedImageContentType(contentType) {
            throw RemoteImageFetchError.unsupportedContentType(contentType)
        }

        guard data.count <= maxImageBytes else {
            throw RemoteImageFetchError.decodedImageTooLarge(data.count)
        }

        return data
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
