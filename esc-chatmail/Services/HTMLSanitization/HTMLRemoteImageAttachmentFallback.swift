import Foundation
import UIKit

/// Rewrites a narrow set of remote HTML images to data URLs when the host serves them as
/// downloadable attachments instead of inline image resources.
actor HTMLRemoteImageAttachmentFallback {
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = HTMLRemoteImageAttachmentFallback()

    private struct ImageSourceMatch {
        let originalURL: String
        let resolvedURL: String
        let range: NSRange
    }

    private enum FallbackError: Error {
        case unsupportedResponse
    }

    private static let imageSourceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<img\b[^>]*?\bsrc\s*=\s*(['"])([^"']+)\1"#,
            options: [.caseInsensitive]
        )
    }()

    private static let supportedImageMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
        "image/bmp",
        "image/x-icon",
        "image/vnd.microsoft.icon"
    ]

    private static let dynamicNonImageExtensions: Set<String> = [
        "php",
        "asp",
        "aspx",
        "jsp",
        "cgi",
        "do",
        "action"
    ]

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private let requestExecutor: RequestExecutor
    private var rewrittenDataURLCache: [String: String] = [:]
    private var unchangedURLCache = BoundedSet<String>(maxSize: 500, prunePercentage: 0.2)
    private let maxCandidatesPerDocument = 6
    private let maxInlineBytes = 2 * 1024 * 1024

    init(requestExecutor: @escaping RequestExecutor = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.requestExecutor = requestExecutor
    }

    func inlineAttachmentStyleImages(in html: String, senderEmail: String?) async -> String {
        let matches = Self.imageSourceMatches(in: html)
        guard !matches.isEmpty else { return html }

        let senderBaseURL = EmailSenderBaseURLResolver.baseURL(from: senderEmail)
        let candidateURLs = eligibleCandidateURLs(from: matches)
        guard !candidateURLs.isEmpty else { return html }

        var rewrittenURLs: [String: String] = [:]
        for url in candidateURLs {
            if let dataURL = await resolvedDataURL(for: url, senderBaseURL: senderBaseURL) {
                rewrittenURLs[url] = dataURL
            }
        }

        guard !rewrittenURLs.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard let replacement = rewrittenURLs[match.resolvedURL],
                  let range = Range(match.range, in: result) else {
                continue
            }

            result.replaceSubrange(range, with: replacement)
        }

        return result
    }

    private func eligibleCandidateURLs(from matches: [ImageSourceMatch]) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        for match in matches {
            guard let url = URL(string: match.resolvedURL),
                  isEligibleCandidate(url),
                  seen.insert(match.resolvedURL).inserted else {
                continue
            }

            candidates.append(match.resolvedURL)
            if candidates.count >= maxCandidatesPerDocument {
                break
            }
        }

        return candidates
    }

    private func resolvedDataURL(for urlString: String, senderBaseURL: URL?) async -> String? {
        let cacheKey = cacheKey(for: urlString, senderBaseURL: senderBaseURL)
        if let cached = rewrittenDataURLCache[cacheKey] {
            return cached
        }
        if unchangedURLCache.contains(cacheKey) {
            return nil
        }

        guard let url = URL(string: urlString) else {
            unchangedURLCache.insert(cacheKey)
            return nil
        }

        do {
            let headResponse = try await execute(request(for: url, method: "HEAD", senderBaseURL: senderBaseURL))
            guard shouldInlineImage(from: headResponse.response) else {
                unchangedURLCache.insert(cacheKey)
                return nil
            }

            if let contentLength = contentLength(from: headResponse.response),
               contentLength > maxInlineBytes {
                unchangedURLCache.insert(cacheKey)
                return nil
            }

            let getResponse = try await execute(request(for: url, method: "GET", senderBaseURL: senderBaseURL))
            guard let dataURL = makeDataURL(from: getResponse.data, response: getResponse.response) else {
                unchangedURLCache.insert(cacheKey)
                return nil
            }

            rewrittenDataURLCache[cacheKey] = dataURL
            return dataURL
        } catch {
            unchangedURLCache.insert(cacheKey)
            Log.debug(
                "Attachment-style remote image fallback failed for \(url.host ?? "unknown"): \(error.localizedDescription)",
                category: .ui
            )
            return nil
        }
    }

    private func execute(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await requestExecutor(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw FallbackError.unsupportedResponse
        }

        return (data, httpResponse)
    }

    private func request(for url: URL, method: String, senderBaseURL: URL?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10.0
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if let senderBaseURL {
            request.setValue(senderBaseURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

        return request
    }

    private func shouldInlineImage(from response: HTTPURLResponse) -> Bool {
        guard let mimeType = response.mimeType?.lowercased(),
              Self.supportedImageMimeTypes.contains(mimeType) else {
            return false
        }

        let disposition = headerValue("Content-Disposition", from: response)?.lowercased() ?? ""
        return disposition.contains("attachment")
    }

    private func makeDataURL(from data: Data, response: HTTPURLResponse) -> String? {
        guard !data.isEmpty,
              data.count <= maxInlineBytes,
              let mimeType = response.mimeType?.lowercased(),
              Self.supportedImageMimeTypes.contains(mimeType),
              UIImage(data: data) != nil else {
            return nil
        }

        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64? {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }

        guard let rawValue = headerValue("Content-Length", from: response),
              let value = Int64(rawValue),
              value > 0 else {
            return nil
        }

        return value
    }

    private func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    private func cacheKey(for urlString: String, senderBaseURL: URL?) -> String {
        let referer = senderBaseURL?.absoluteString ?? "-"
        return "\(referer)|\(urlString)"
    }

    private func isEligibleCandidate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        let path = url.path.lowercased()
        let pathExtension = url.pathExtension.lowercased()

        if host.hasSuffix("file.force.com") || path.contains("/file-asset-public/") {
            return true
        }

        if pathExtension.isEmpty {
            return true
        }

        return Self.dynamicNonImageExtensions.contains(pathExtension)
    }

    private static func imageSourceMatches(in html: String) -> [ImageSourceMatch] {
        let range = NSRange(html.startIndex..., in: html)
        return imageSourceRegex.matches(in: html, range: range).compactMap { match in
            guard let urlRange = Range(match.range(at: 2), in: html) else {
                return nil
            }

            let originalURL = String(html[urlRange])
            let resolvedURL = HTMLEntityDecoder.decode(originalURL)
            return ImageSourceMatch(
                originalURL: originalURL,
                resolvedURL: resolvedURL,
                range: match.range(at: 2)
            )
        }
    }
}
