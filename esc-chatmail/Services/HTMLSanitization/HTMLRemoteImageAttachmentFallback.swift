import Foundation
import UIKit

/// Rewrites a narrow set of remote HTML images to data URLs when the host serves them as
/// downloadable attachments or advertises modern formats (AVIF/WEBP) that WKWebView does not
/// always decode reliably in newsletter previews.
actor HTMLRemoteImageAttachmentFallback {
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = HTMLRemoteImageAttachmentFallback()

    struct CachedRewriteResult {
        let html: String
        let hasPendingUpdates: Bool
        let needsWarmup: Bool
    }

    private struct ImageSourceMatch {
        let resolvedURL: String
        let range: NSRange
    }

    private enum DataURLResolutionResult: Sendable {
        case rewritten(String)
        case unchanged
        case transientFailure(String)
    }

    private enum FinalizedDataURLResolutionResult: Sendable {
        case rewritten(String)
        case unchanged
        case transientFailure
    }

    private enum PreviewDataURLResolutionResult: Sendable {
        case rewritten(String)
        case unchanged
        case pending
    }

    private final class PreviewResolutionContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PreviewDataURLResolutionResult, Never>?

        init(_ continuation: CheckedContinuation<PreviewDataURLResolutionResult, Never>) {
            self.continuation = continuation
        }

        func resume(returning result: PreviewDataURLResolutionResult) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            continuation?.resume(returning: result)
        }
    }

    private struct CostBoundedStringCache: Sendable {
        private var values: [String: String] = [:]
        private var costs: [String: Int] = [:]
        private var usageOrder: [String] = []
        private let maxEntries: Int
        private let maxTotalCost: Int
        private var currentTotalCost = 0

        init(maxEntries: Int, maxTotalCost: Int) {
            precondition(maxEntries > 0, "maxEntries must be positive")
            precondition(maxTotalCost > 0, "maxTotalCost must be positive")

            self.maxEntries = maxEntries
            self.maxTotalCost = maxTotalCost
        }

        mutating func value(forKey key: String) -> String? {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }

        mutating func insert(_ value: String, forKey key: String, cost: Int) {
            guard cost > 0, cost <= maxTotalCost else { return }

            if let existingCost = costs[key] {
                currentTotalCost -= existingCost
            }
            values[key] = nil
            costs[key] = nil
            usageOrder.removeAll { $0 == key }

            while !usageOrder.isEmpty && (usageOrder.count >= maxEntries || currentTotalCost + cost > maxTotalCost) {
                evictLeastRecentlyUsed()
            }

            values[key] = value
            costs[key] = cost
            usageOrder.append(key)
            currentTotalCost += cost
        }

        private mutating func touch(_ key: String) {
            usageOrder.removeAll { $0 == key }
            usageOrder.append(key)
        }

        private mutating func evictLeastRecentlyUsed() {
            guard let key = usageOrder.first else { return }
            usageOrder.removeFirst()
            if let cost = costs.removeValue(forKey: key) {
                currentTotalCost -= cost
            }
            values.removeValue(forKey: key)
        }
    }

    private static let imageSourceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<img\b[^>]*?\bsrc\s*=\s*(['"])([^"']+)\1"#,
            options: [.caseInsensitive]
        )
    }()

    private static let rewritableSourceImageMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/webp",
        "image/avif",
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
    private var rewrittenDataURLCache: CostBoundedStringCache
    private var unchangedURLCache = BoundedSet<String>(maxSize: 500, prunePercentage: 0.2)
    private var inFlightResolutions: [String: Task<DataURLResolutionResult, Never>] = [:]
    private let maxCandidatesPerDocument = 6
    private let maxInlineBytes = 2 * 1024 * 1024
    private let previewEagerResolutionTimeoutNanoseconds: UInt64

    init(
        requestExecutor: @escaping RequestExecutor = { request in
            try await SSRFGuardingURLSession.shared.data(for: request)
        },
        rewrittenDataURLCacheMaxEntries: Int = 32,
        rewrittenDataURLCacheMaxBytes: Int = 8 * 1024 * 1024,
        previewEagerResolutionTimeout: TimeInterval = 0.3
    ) {
        self.requestExecutor = requestExecutor
        self.rewrittenDataURLCache = CostBoundedStringCache(
            maxEntries: rewrittenDataURLCacheMaxEntries,
            maxTotalCost: rewrittenDataURLCacheMaxBytes
        )
        self.previewEagerResolutionTimeoutNanoseconds = UInt64(max(0, previewEagerResolutionTimeout) * 1_000_000_000)
    }

    func cachedInlineAttachmentStyleImages(in html: String, senderEmail: String?) -> CachedRewriteResult {
        let matches = Self.imageSourceMatches(in: html)
        guard !matches.isEmpty else {
            return CachedRewriteResult(html: html, hasPendingUpdates: false, needsWarmup: false)
        }

        let senderBaseURL = EmailSenderBaseURLResolver.baseURL(from: senderEmail)
        let candidateURLs = eligibleCandidateURLs(from: matches)
        guard !candidateURLs.isEmpty else {
            return CachedRewriteResult(html: html, hasPendingUpdates: false, needsWarmup: false)
        }

        var rewrittenURLs: [String: String] = [:]
        var hasPendingUpdates = false
        var needsWarmup = false

        for url in candidateURLs {
            let cacheKey = cacheKey(for: url, senderBaseURL: senderBaseURL)

            if let cached = rewrittenDataURLCache.value(forKey: cacheKey) {
                rewrittenURLs[url] = cached
                continue
            }

            if unchangedURLCache.contains(cacheKey) {
                continue
            }

            hasPendingUpdates = true
            if inFlightResolutions[cacheKey] == nil {
                needsWarmup = true
            }
        }

        return CachedRewriteResult(
            html: Self.rewritingHTML(html, matches: matches, replacements: rewrittenURLs),
            hasPendingUpdates: hasPendingUpdates,
            needsWarmup: needsWarmup
        )
    }

    func previewInlineAttachmentStyleImages(in html: String, senderEmail: String?) async -> CachedRewriteResult {
        let matches = Self.imageSourceMatches(in: html)
        guard !matches.isEmpty else {
            return CachedRewriteResult(html: html, hasPendingUpdates: false, needsWarmup: false)
        }

        let senderBaseURL = EmailSenderBaseURLResolver.baseURL(from: senderEmail)
        let candidateURLs = eligibleCandidateURLs(from: matches)
        guard !candidateURLs.isEmpty else {
            return CachedRewriteResult(html: html, hasPendingUpdates: false, needsWarmup: false)
        }

        var rewrittenURLs: [String: String] = [:]
        var hasPendingUpdates = false
        var needsWarmup = false
        var eagerResolutionURLs: [String] = []

        for urlString in candidateURLs {
            let cacheKey = cacheKey(for: urlString, senderBaseURL: senderBaseURL)

            if let cached = rewrittenDataURLCache.value(forKey: cacheKey) {
                rewrittenURLs[urlString] = cached
                continue
            }

            if unchangedURLCache.contains(cacheKey) {
                continue
            }

            guard let url = URL(string: urlString),
                  Self.isHighConfidenceAttachmentImageURL(url) else {
                hasPendingUpdates = true
                if inFlightResolutions[cacheKey] == nil {
                    needsWarmup = true
                }
                continue
            }

            eagerResolutionURLs.append(urlString)
        }

        let eagerResults = await previewResolvedDataURLs(
            for: eagerResolutionURLs,
            senderBaseURL: senderBaseURL,
            timeoutNanoseconds: previewEagerResolutionTimeoutNanoseconds
        )
        for urlString in eagerResolutionURLs {
            switch eagerResults[urlString] ?? .pending {
            case .rewritten(let dataURL):
                rewrittenURLs[urlString] = dataURL
            case .unchanged:
                continue
            case .pending:
                hasPendingUpdates = true
                needsWarmup = true
            }
        }

        return CachedRewriteResult(
            html: Self.rewritingHTML(html, matches: matches, replacements: rewrittenURLs),
            hasPendingUpdates: hasPendingUpdates,
            needsWarmup: needsWarmup
        )
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

        return Self.rewritingHTML(html, matches: matches, replacements: rewrittenURLs)
    }

    private func previewResolvedDataURLs(
        for urlStrings: [String],
        senderBaseURL: URL?,
        timeoutNanoseconds: UInt64
    ) async -> [String: PreviewDataURLResolutionResult] {
        guard !urlStrings.isEmpty else { return [:] }

        return await withTaskGroup(
            of: (String, PreviewDataURLResolutionResult).self,
            returning: [String: PreviewDataURLResolutionResult].self
        ) { group in
            for urlString in urlStrings {
                group.addTask { [self, senderBaseURL] in
                    let result = await previewResolvedDataURL(
                        for: urlString,
                        senderBaseURL: senderBaseURL,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                    return (urlString, result)
                }
            }

            var results: [String: PreviewDataURLResolutionResult] = [:]
            for await (urlString, result) in group {
                results[urlString] = result
            }
            return results
        }
    }

    private func previewResolvedDataURL(
        for urlString: String,
        senderBaseURL: URL?,
        timeoutNanoseconds: UInt64
    ) async -> PreviewDataURLResolutionResult {
        let cacheKey = cacheKey(for: urlString, senderBaseURL: senderBaseURL)
        if let cached = rewrittenDataURLCache.value(forKey: cacheKey) {
            return .rewritten(cached)
        }
        if unchangedURLCache.contains(cacheKey) {
            return .unchanged
        }

        guard let task = dataURLResolutionTask(for: urlString, senderBaseURL: senderBaseURL, cacheKey: cacheKey) else {
            return .unchanged
        }

        return await withCheckedContinuation { continuation in
            let gate = PreviewResolutionContinuation(continuation)

            Task { [self] in
                let result = await task.value
                let finalized = await finalizeResolution(result, cacheKey: cacheKey)
                switch finalized {
                case .rewritten(let dataURL):
                    gate.resume(returning: .rewritten(dataURL))
                case .unchanged:
                    gate.resume(returning: .unchanged)
                case .transientFailure:
                    gate.resume(returning: .pending)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                gate.resume(returning: .pending)
            }
        }
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
        if let cached = rewrittenDataURLCache.value(forKey: cacheKey) {
            return cached
        }
        if unchangedURLCache.contains(cacheKey) {
            return nil
        }

        guard let task = dataURLResolutionTask(for: urlString, senderBaseURL: senderBaseURL, cacheKey: cacheKey) else {
            return nil
        }

        switch await finalizeResolution(task, cacheKey: cacheKey) {
        case .rewritten(let dataURL):
            return dataURL
        case .unchanged, .transientFailure:
            return nil
        }
    }

    private func dataURLResolutionTask(
        for urlString: String,
        senderBaseURL: URL?,
        cacheKey: String
    ) -> Task<DataURLResolutionResult, Never>? {
        if let inFlightTask = inFlightResolutions[cacheKey] {
            return inFlightTask
        }

        guard let url = URL(string: urlString) else {
            unchangedURLCache.insert(cacheKey)
            return nil
        }

        let requestExecutor = self.requestExecutor
        let maxInlineBytes = self.maxInlineBytes
        let task = Task<DataURLResolutionResult, Never> {
            await Self.resolveDataURL(
                for: url,
                senderBaseURL: senderBaseURL,
                requestExecutor: requestExecutor,
                maxInlineBytes: maxInlineBytes
            )
        }
        inFlightResolutions[cacheKey] = task
        return task
    }

    private func finalizeResolution(
        _ task: Task<DataURLResolutionResult, Never>,
        cacheKey: String
    ) async -> FinalizedDataURLResolutionResult {
        let result = await task.value
        return finalizeResolution(result, cacheKey: cacheKey)
    }

    private func finalizeResolution(
        _ result: DataURLResolutionResult,
        cacheKey: String
    ) -> FinalizedDataURLResolutionResult {
        inFlightResolutions[cacheKey] = nil

        switch result {
        case .rewritten(let dataURL):
            rewrittenDataURLCache.insert(dataURL, forKey: cacheKey, cost: dataURL.utf8.count)
            unchangedURLCache.remove(cacheKey)
            return .rewritten(dataURL)
        case .unchanged:
            unchangedURLCache.insert(cacheKey)
            return .unchanged
        case .transientFailure(let description):
            Log.debug("Attachment-style remote image fallback failed: \(description)", category: .ui)
            return .transientFailure
        }
    }

    private static func resolveDataURL(
        for url: URL,
        senderBaseURL: URL?,
        requestExecutor: @escaping RequestExecutor,
        maxInlineBytes: Int
    ) async -> DataURLResolutionResult {
        do {
            let headResponse = try await execute(
                request(for: url, method: "HEAD", senderBaseURL: senderBaseURL),
                requestExecutor: requestExecutor
            )
            guard shouldInlineImage(from: headResponse.response, originalURL: url) else {
                return .unchanged
            }

            if let contentLength = contentLength(from: headResponse.response),
               contentLength > Int64(maxInlineBytes) {
                return .unchanged
            }

            let getResponse = try await execute(
                request(for: url, method: "GET", senderBaseURL: senderBaseURL),
                requestExecutor: requestExecutor
            )
            guard let dataURL = makeDataURL(
                from: getResponse.data,
                response: getResponse.response,
                maxInlineBytes: maxInlineBytes
            ) else {
                return .unchanged
            }

            return .rewritten(dataURL)
        } catch is CancellationError {
            return .transientFailure("cancelled for \(url.host ?? "unknown")")
        } catch {
            return .transientFailure("\(url.host ?? "unknown"): \(error.localizedDescription)")
        }
    }

    private static func execute(
        _ request: URLRequest,
        requestExecutor: @escaping RequestExecutor
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await requestExecutor(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return (data, httpResponse)
    }

    private static func request(for url: URL, method: String, senderBaseURL: URL?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10.0
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/png,image/jpeg,image/gif,image/bmp,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")

        if let senderBaseURL {
            request.setValue(senderBaseURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

        return request
    }

    private static func shouldInlineImage(from response: HTTPURLResponse, originalURL: URL) -> Bool {
        guard let mimeType = response.mimeType?.lowercased(),
              Self.rewritableSourceImageMimeTypes.contains(mimeType) else {
            return false
        }

        let disposition = headerValue("Content-Disposition", from: response)?.lowercased() ?? ""
        if disposition.contains("attachment") {
            return true
        }

        return isRiskyModernImageURL(originalURL) || mimeType == "image/avif" || mimeType == "image/webp"
    }

    private static func makeDataURL(from data: Data, response: HTTPURLResponse, maxInlineBytes: Int) -> String? {
        guard !data.isEmpty,
              data.count <= maxInlineBytes,
              let mimeType = response.mimeType?.lowercased(),
              Self.rewritableSourceImageMimeTypes.contains(mimeType),
              let image = UIImage(data: data) else {
            return nil
        }

        if let pngData = image.pngData(), pngData.count <= maxInlineBytes {
            return "data:image/png;base64,\(pngData.base64EncodedString())"
        }

        if let jpegData = image.jpegData(compressionQuality: 0.92), jpegData.count <= maxInlineBytes {
            return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        }

        return nil
    }

    private static func contentLength(from response: HTTPURLResponse) -> Int64? {
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

    private static func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
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

        // SSRF guard: never fetch URLs from email HTML that target private,
        // loopback, link-local, or reserved addresses. Pairs with the
        // redirect-blocking delegate in SSRFGuardingURLSession so an attacker
        // can't bypass via public-looking host → 302 → internal IP.
        if PrivateNetworkAddressDetector.isPrivateOrReserved(url) {
            return false
        }

        if Self.isRiskyModernImageURL(url) {
            return true
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

    private static func isRiskyModernImageURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "avif" || pathExtension == "webp" {
            return true
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return false
        }

        for item in queryItems {
            guard let value = item.value?.lowercased() else { continue }

            switch item.name.lowercased() {
            case "format":
                if value == "auto" || value == "avif" || value == "webp" {
                    return true
                }
            case "fm":
                if value == "avif" || value == "webp" {
                    return true
                }
            default:
                continue
            }
        }

        return false
    }

    private static func isHighConfidenceAttachmentImageURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host.hasSuffix("file.force.com") || path.contains("/file-asset-public/")
    }

    private static func imageSourceMatches(in html: String) -> [ImageSourceMatch] {
        let range = NSRange(html.startIndex..., in: html)
        return imageSourceRegex.matches(in: html, range: range).compactMap { match in
            guard let urlRange = Range(match.range(at: 2), in: html) else {
                return nil
            }

            let resolvedURL = HTMLEntityDecoder.decode(String(html[urlRange]))
            return ImageSourceMatch(
                resolvedURL: resolvedURL,
                range: match.range(at: 2)
            )
        }
    }

    private static func rewritingHTML(
        _ html: String,
        matches: [ImageSourceMatch],
        replacements: [String: String]
    ) -> String {
        var result = html
        for match in matches.reversed() {
            guard let replacement = replacements[match.resolvedURL],
                  let range = Range(match.range, in: result) else {
                continue
            }

            result.replaceSubrange(range, with: replacement)
        }

        return result
    }
}
