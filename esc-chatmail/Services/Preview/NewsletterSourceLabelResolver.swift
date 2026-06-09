import Foundation

/// Resolves the "source" label for a newsletter preview — the human-readable
/// publisher name shown on the card — from the sender's display name, falling
/// back to a capitalized primary segment of the sending domain.
///
/// Extracted from `NewsletterPreviewBuilder` so the sender/domain labeling lives
/// in one focused, independently testable unit. The shared `PreviewLineProcessor`
/// (used only for truncation) is injected; the ignored-subdomain list moves here
/// with the logic since nothing else references it.
struct NewsletterSourceLabelResolver {
    private let lineProcessor: PreviewLineProcessor

    init(lineProcessor: PreviewLineProcessor) {
        self.lineProcessor = lineProcessor
    }

    func sourceLabel(senderName: String?, senderEmail: String?, sourceDomain: String?) -> String? {
        if let senderName = normalizedSenderName(senderName, senderEmail: senderEmail) {
            return lineProcessor.truncate(senderName, limit: 40)
        }

        guard let sourceDomain, !sourceDomain.isEmpty else {
            return nil
        }

        let primarySegment = sourceDomain
            .split(separator: ".")
            .map(String.init)
            .first(where: { segment in
                let lowercased = segment.lowercased()
                return lowercased.count > 1 && !ignoredSourceSubdomains.contains(lowercased)
            })?
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let primarySegment, !primarySegment.isEmpty else {
            return nil
        }

        return primarySegment.capitalized
    }

    private func normalizedSenderName(_ senderName: String?, senderEmail: String?) -> String? {
        if let senderEmail {
            return PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                senderName,
                forEmail: senderEmail
            )
        }

        let normalized = PreviewTextUtilities.normalizedText(senderName)
        guard !normalized.isEmpty,
              !normalized.contains("@") else {
            return nil
        }

        return normalized
    }
}

private let ignoredSourceSubdomains: Set<String> = [
    "cdn",
    "click",
    "e",
    "email",
    "em",
    "img",
    "image",
    "links",
    "m",
    "mail",
    "mailer",
    "news",
    "newsletter",
    "notifications",
    "notify",
    "track",
    "tracking",
    "updates",
    "www"
]
