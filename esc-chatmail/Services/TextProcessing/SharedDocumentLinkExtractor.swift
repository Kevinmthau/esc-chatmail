import Foundation

struct SharedDocumentLink: Identifiable, Equatable {
    enum Kind: Equatable {
        case googleSheet
        case googleDoc
        case googleSlides
        case googleDriveFile
        case googleDriveFolder

        var title: String {
            switch self {
            case .googleSheet:
                return "Google Sheet"
            case .googleDoc:
                return "Google Doc"
            case .googleSlides:
                return "Google Slides"
            case .googleDriveFile:
                return "Google Drive File"
            case .googleDriveFolder:
                return "Google Drive Folder"
            }
        }
    }

    let id: String
    let url: URL
    let kind: Kind

    var hostDisplay: String {
        url.host?.lowercased() ?? url.absoluteString
    }
}

enum SharedDocumentLinkExtractor {
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func extract(from textCandidates: [String], maxCount: Int = 4) -> [SharedDocumentLink] {
        guard maxCount > 0, let detector = linkDetector else {
            return []
        }

        var links: [SharedDocumentLink] = []
        var seenKeys = Set<String>()

        for text in textCandidates where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let rawURL = match.url,
                      let normalizedURL = normalizedHTTPURL(from: rawURL),
                      let kind = googleWorkspaceKind(for: normalizedURL) else {
                    continue
                }

                let dedupeKey = dedupeKey(for: normalizedURL, kind: kind)
                guard seenKeys.insert(dedupeKey).inserted else {
                    continue
                }

                links.append(
                    SharedDocumentLink(
                        id: dedupeKey,
                        url: normalizedURL,
                        kind: kind
                    )
                )

                if links.count >= maxCount {
                    return links
                }
            }
        }

        return links
    }

    private static func normalizedHTTPURL(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    private static func googleWorkspaceKind(for url: URL) -> SharedDocumentLink.Kind? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        let path = url.path.lowercased()

        switch host {
        case "docs.google.com":
            if path.contains("/spreadsheets/") {
                return .googleSheet
            }
            if path.contains("/document/") {
                return .googleDoc
            }
            if path.contains("/presentation/") {
                return .googleSlides
            }
            if path.contains("/file/") {
                return .googleDriveFile
            }
            return nil

        case "drive.google.com":
            if path.contains("/drive/folders/") {
                return .googleDriveFolder
            }
            if path.contains("/file/") || path == "/open" || path.hasPrefix("/uc") {
                return .googleDriveFile
            }
            return nil

        default:
            return nil
        }
    }

    private static func dedupeKey(for url: URL, kind: SharedDocumentLink.Kind) -> String {
        if let resourceId = googleResourceId(from: url) {
            return "\(kind)|\(resourceId.lowercased())"
        }

        let host = url.host?.lowercased() ?? ""
        var path = url.path.lowercased()
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        return "\(kind)|\(host)\(path)"
    }

    private static func googleResourceId(from url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }

        if let dIndex = components.firstIndex(of: "d"),
           components.indices.contains(dIndex + 1) {
            return components[dIndex + 1]
        }

        if let foldersIndex = components.firstIndex(of: "folders"),
           components.indices.contains(foldersIndex + 1) {
            return components[foldersIndex + 1]
        }

        if url.path.lowercased() == "/open",
           let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = queryItems.first(where: { $0.name.lowercased() == "id" })?.value,
           !id.isEmpty {
            return id
        }

        return nil
    }
}
