import Foundation

struct GoogleDriveSharedFileMetadata: Equatable, Sendable {
    let title: String
    let thumbnailURL: String?
}

actor GoogleDriveSharedFileMetadataProvider {
    static let shared = GoogleDriveSharedFileMetadataProvider()

    private let session: URLSession
    private let requestManager = InFlightRequestManager<String, GoogleDriveSharedFileMetadata>(
        maxFailedKeys: 256
    )
    private var cachedMetadata: [String: GoogleDriveSharedFileMetadata] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(for link: SharedDocumentLink) async -> GoogleDriveSharedFileMetadata {
        let cacheKey = link.id

        if let cached = cachedMetadata[cacheKey] {
            return cached
        }

        guard link.supportsAttachmentPreviewCard else {
            return Self.fallbackMetadata(for: link)
        }

        let session = self.session
        let fetchedMetadata = await requestManager.deduplicatedWithFailureTracking(key: cacheKey) {
            await Self.fetchMetadata(for: link, session: session)
        }

        let resolvedMetadata = fetchedMetadata ?? Self.fallbackMetadata(for: link)

        if fetchedMetadata != nil {
            cachedMetadata[cacheKey] = resolvedMetadata
        }

        return resolvedMetadata
    }

    static func fallbackMetadata(for link: SharedDocumentLink) -> GoogleDriveSharedFileMetadata {
        GoogleDriveSharedFileMetadata(
            title: link.kind.title,
            thumbnailURL: fallbackThumbnailURL(for: link)
        )
    }

    static func parseMetadata(
        from html: String,
        link: SharedDocumentLink
    ) -> GoogleDriveSharedFileMetadata? {
        let resolvedTitle = normalizedTitle(
            extractMetaContent(named: "og:title", from: html) ??
            extractMetaContent(named: "twitter:title", from: html) ??
            extractTitleTag(from: html),
            link: link
        ) ?? link.kind.title

        let resolvedThumbnailURL =
            normalizedURLString(
                extractMetaContent(named: "og:image", from: html) ??
                extractMetaContent(named: "twitter:image", from: html)
            ) ??
            fallbackThumbnailURL(for: link)

        return GoogleDriveSharedFileMetadata(
            title: resolvedTitle,
            thumbnailURL: resolvedThumbnailURL
        )
    }

    private static func fetchMetadata(
        for link: SharedDocumentLink,
        session: URLSession
    ) async -> GoogleDriveSharedFileMetadata? {
        guard link.supportsAttachmentPreviewCard else {
            return nil
        }

        var request = URLRequest(url: link.url)
        request.timeoutInterval = 10
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  !data.isEmpty else {
                return nil
            }

            guard let html = decodedHTML(from: data) else {
                return nil
            }

            return parseMetadata(from: html, link: link)
        } catch {
            return nil
        }
    }

    private static func decodedHTML(from data: Data) -> String? {
        if let utf8String = String(data: data, encoding: .utf8), !utf8String.isEmpty {
            return utf8String
        }

        if let unicodeString = String(data: data, encoding: .unicode), !unicodeString.isEmpty {
            return unicodeString
        }

        if let asciiString = String(data: data, encoding: .ascii), !asciiString.isEmpty {
            return asciiString
        }

        let lossyString = String(decoding: data, as: UTF8.self)
        return lossyString.isEmpty ? nil : lossyString
    }

    private static func extractMetaContent(named name: String, from html: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "<meta\\b[^>]*(?:property|name)\\s*=\\s*[\"']\(escapedName)[\"'][^>]*content\\s*=\\s*([\"'])([\\s\\S]*?)\\1[^>]*>",
            "<meta\\b[^>]*content\\s*=\\s*([\"'])([\\s\\S]*?)\\1[^>]*(?:property|name)\\s*=\\s*([\"'])\(escapedName)\\3[^>]*>",
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  let contentRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            return String(html[contentRange])
        }

        return nil
    }

    private static func extractTitleTag(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title\\b[^>]*>([\\s\\S]*?)</title>",
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return String(html[titleRange])
    }

    private static func normalizedTitle(_ rawTitle: String?, link: SharedDocumentLink) -> String? {
        guard let rawTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else {
            return nil
        }

        var title = HTMLEntityDecoder.decode(rawTitle)
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let suffixPatterns = [
            "\\s[-–]\\sGoogle Docs$",
            "\\s[-–]\\sGoogle Sheets$",
            "\\s[-–]\\sGoogle Slides$",
            "\\s[-–]\\sGoogle Drive$",
        ]

        for pattern in suffixPatterns {
            title = title.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        let genericTitles = Set([
            "google docs",
            "google sheets",
            "google slides",
            "google drive",
            "access denied - google docs",
            "sign in - google accounts",
            "google docs: sign-in",
            "google drive: sign-in",
        ])

        let lowercasedTitle = title.lowercased()
        guard !genericTitles.contains(lowercasedTitle) else {
            return nil
        }

        if lowercasedTitle.hasPrefix("sign in") || lowercasedTitle.hasPrefix("access denied") {
            return nil
        }

        return title.isEmpty ? link.kind.title : title
    }

    private static func normalizedURLString(_ rawURL: String?) -> String? {
        guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return nil
        }

        let decodedURL = HTMLEntityDecoder.decode(rawURL)
        guard let url = URL(string: decodedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return url.absoluteString
    }

    private static func fallbackThumbnailURL(for link: SharedDocumentLink) -> String? {
        guard link.supportsAttachmentPreviewCard,
              let resourceID = link.resourceID,
              !resourceID.isEmpty else {
            return nil
        }

        return "https://drive.google.com/thumbnail?id=\(resourceID)&sz=w1600"
    }
}
