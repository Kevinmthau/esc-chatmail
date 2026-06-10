import Foundation

enum PreviewTextUtilities {
    static func normalizedText(_ text: String?) -> String {
        EmailPreviewContentExtractor.normalizedText(text)
    }

    static func normalizedPreviewText(_ text: String?) -> String? {
        let normalized = normalizedText(text)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedComparableText(_ text: String?) -> String {
        normalizedText(text).lowercased()
    }

    static func normalizedSet(from strings: [String?]) -> Set<String> {
        Set(strings.compactMap { value in
            let normalized = normalizedComparableText(value)
            return normalized.isEmpty ? nil : normalized
        })
    }

    static func normalizedSourceDomain(from senderEmail: String?) -> String? {
        guard let senderEmail = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !senderEmail.isEmpty else {
            return nil
        }

        let extractedEmail = EmailNormalizer.extractEmail(from: senderEmail) ?? senderEmail
        guard let atIndex = extractedEmail.lastIndex(of: "@"),
              atIndex < extractedEmail.index(before: extractedEmail.endIndex) else {
            return nil
        }

        let domain = extractedEmail[extractedEmail.index(after: atIndex)...]
            .lowercased()
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'()[],:;"))

        return domain.isEmpty ? nil : domain
    }

    /// Trust checks must anchor on the parsed sender domain: substring matching on
    /// the raw sender string accepts spoofs like "a@email.apple.com.evil.com" and
    /// display-name forgeries like "notifications@github.com <a@evil.com>".
    static func senderDomain(_ senderEmail: String?, matchesDomainOrSuffixIn domainSuffixes: Set<String>) -> Bool {
        domain(normalizedSourceDomain(from: senderEmail), matchesDomainOrSuffixIn: domainSuffixes)
    }

    static func domain(_ domain: String?, matchesDomainOrSuffixIn domainSuffixes: Set<String>) -> Bool {
        guard let domain = domain?.lowercased(), !domain.isEmpty else {
            return false
        }

        return domainSuffixes.contains { suffix in
            domain == suffix || domain.hasSuffix(".\(suffix)")
        }
    }

    static func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }

        return Double(width) / Double(height)
    }

    static func isRenderableRemoteImageURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !lowercased.isEmpty,
              !lowercased.hasPrefix("cid:"),
              !lowercased.hasPrefix("data:"),
              !lowercased.contains("about:blank"),
              let parsedURL = URL(string: trimmed),
              let scheme = parsedURL.scheme?.lowercased(),
              let host = parsedURL.host,
              !host.isEmpty else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }
}
