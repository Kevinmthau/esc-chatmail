import Foundation

struct SharedDocumentLink: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
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

        var supportsAttachmentPreviewCard: Bool {
            switch self {
            case .googleSheet, .googleDoc, .googleSlides:
                return true
            case .googleDriveFile, .googleDriveFolder:
                return false
            }
        }
    }

    let id: String
    let url: URL
    let kind: Kind

    var hostDisplay: String {
        url.host?.lowercased() ?? url.absoluteString
    }

    var sourceLabel: String {
        kind.supportsAttachmentPreviewCard ? "docs.google.com" : hostDisplay
    }

    var resourceID: String? {
        SharedDocumentLinkExtractor.googleResourceId(from: url)
    }

    var supportsAttachmentPreviewCard: Bool {
        kind.supportsAttachmentPreviewCard
    }
}

enum SharedDocumentLinkExtractor {
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Whether any of these texts spells a host `extract` accepts, without running the data
    /// detector. `googleWorkspaceKind` accepts only `docs.google.com` and `drive.google.com`,
    /// compared lowercased, so a text that spells `google.com` in no letter case has no
    /// literally spelled link. True does not mean a link exists.
    ///
    /// Not a strict superset of `extract`. Foundation also resolves a percent-encoded host
    /// (`docs.%67oogle.com`) and compatibility or ignorable characters in one (full-width
    /// letters, a soft hyphen) to `docs.google.com`, and those spellings are missed here.
    /// Normalising for them would cost a second pass over every non-ASCII body, which is most
    /// mail, for a spelling ordinary links never use.
    ///
    /// Searched through `NSString` on purpose: this runs on the main actor for every row of
    /// every window re-map (`Message.storedSharedDocumentLinks`), over the whole plain-text
    /// body. Measured on a 10 KB body (macOS, optimized): about 4 to 6 ns/byte this way, 75 to
    /// 80 ns/byte through the Swift `String.range(of:options:)` overload, and 125 to 155
    /// ns/byte for the data detector pass it stands in front of. Do not simplify it back.
    /// Keep the needle in step with `googleWorkspaceKind` if it ever accepts another host.
    static func mayContainLinks(in textCandidates: [String?]) -> Bool {
        textCandidates.contains { text in
            guard let text else { return false }
            return (text as NSString)
                .range(of: "google.com", options: [.caseInsensitive, .literal])
                .location != NSNotFound
        }
    }

    /// The most links one bubble shows cards for.
    static let bubbleLinkLimit = 4

    /// The shared-document links a chat bubble shows for a message, searched in the order the
    /// bubble prefers its texts. The one definition for the bubble's content load
    /// (`MessageBubbleLoader.loadContent`) and for the links a row carries before that load
    /// (`storedRowLinks`): the bubble strips these links' URLs from its text and appends a card
    /// for each, so two definitions that disagreed on order, trimming or the limit would
    /// re-render a mounted row when its load publishes.
    static func bubbleLinks(
        preferredText: String?,
        bodyText: String?,
        snippet: String?
    ) -> [SharedDocumentLink] {
        let candidates = [preferredText, bodyText, snippet]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return extract(from: candidates, maxCount: bubbleLinkLimit)
    }

    /// Whether a row's stored fields decide the links its content load will publish, and could
    /// hold one. The cheap half of `storedRowLinks`, split out so a caller that memoizes the
    /// expensive half can skip its bookkeeping for the rows this rejects, which is nearly all
    /// of them.
    ///
    /// Stored fields decide the links exactly where the load searches the stored
    /// `chatPreviewText` first (`MessageBubbleLoader.loadContent`):
    ///
    /// - not a forwarded row: the load searches a parsed forward's lead-in instead, and
    ///   neither `bodyText` nor `snippet`. The bubble shows no document cards for a forward
    ///   before its load in any case (the loading pill, or an own forward's summary card);
    /// - a non-blank `chatPreviewText`: without one the load searches the text its
    ///   compatibility path derives, which is not stored.
    ///
    /// `mayContainLinks` runs last: it is the only check that reads the body.
    static func storedRowMayCarryLinks(
        chatPreviewText: String?,
        bodyText: String?,
        snippet: String?,
        isForwardedEmail: Bool
    ) -> Bool {
        !isForwardedEmail &&
            MessagePreviewText.nonEmpty(chatPreviewText) != nil &&
            mayContainLinks(in: [chatPreviewText, bodyText, snippet])
    }

    /// The links a row's content load will publish, from stored fields alone, so the bubble
    /// can mount with them instead of showing a raw URL and swapping to text plus a card when
    /// the load lands. Empty where stored fields do not decide them
    /// (`storedRowMayCarryLinks`), and the bubble then has no links until its load publishes.
    ///
    /// One spelling is missed: a link `mayContainLinks` does not see (an encoded host) is
    /// absent here and present in the load's result, so that row still swaps after mount. The
    /// load stays the authority once it has published (`MessageDisplayPolicy.sharedDocumentLinks`).
    static func storedRowLinks(
        chatPreviewText: String?,
        bodyText: String?,
        snippet: String?,
        isForwardedEmail: Bool
    ) -> [SharedDocumentLink] {
        guard storedRowMayCarryLinks(
            chatPreviewText: chatPreviewText,
            bodyText: bodyText,
            snippet: snippet,
            isForwardedEmail: isForwardedEmail
        ) else {
            return []
        }
        return bubbleLinks(preferredText: chatPreviewText, bodyText: bodyText, snippet: snippet)
    }

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

    static func removingLinks(from text: String?, matching links: [SharedDocumentLink]) -> String? {
        guard let detector = linkDetector else {
            return text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !links.isEmpty else {
            return text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let removableIDs = Set(links.map(\.id))
        let range = NSRange(text.startIndex..., in: text)
        var removableRanges: [NSRange] = []

        for match in detector.matches(in: text, options: [], range: range) {
            guard let rawURL = match.url,
                  let normalizedURL = normalizedHTTPURL(from: rawURL),
                  let kind = googleWorkspaceKind(for: normalizedURL) else {
                continue
            }

            let dedupeKey = dedupeKey(for: normalizedURL, kind: kind)
            guard removableIDs.contains(dedupeKey) else {
                continue
            }

            removableRanges.append(match.range)
        }

        guard !removableRanges.isEmpty else {
            return text
        }

        var cleanedText = text
        for removableRange in removableRanges.sorted(by: { $0.location > $1.location }) {
            guard let swiftRange = Range(removableRange, in: cleanedText) else {
                continue
            }
            cleanedText.removeSubrange(swiftRange)
        }

        cleanedText = cleanedText.replacingOccurrences(
            of: "[ \\t]{2,}",
            with: " ",
            options: .regularExpression
        )
        cleanedText = cleanedText.replacingOccurrences(
            of: "\\n[ \\t]+",
            with: "\n",
            options: .regularExpression
        )
        cleanedText = cleanedText.replacingOccurrences(
            of: "[ \\t]+\\n",
            with: "\n",
            options: .regularExpression
        )
        cleanedText = cleanedText.replacingOccurrences(
            of: "(\\n\\s*){3,}",
            with: "\n\n",
            options: .regularExpression
        )

        let trimmed = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedHTTPURL(from url: URL) -> URL? {
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

    static func googleWorkspaceKind(for url: URL) -> SharedDocumentLink.Kind? {
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

    static func dedupeKey(for url: URL, kind: SharedDocumentLink.Kind) -> String {
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

    static func googleResourceId(from url: URL) -> String? {
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
