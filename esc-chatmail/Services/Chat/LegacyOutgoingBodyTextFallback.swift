import Foundation

/// Legacy compatibility for outgoing records created before chatPreviewText was
/// populated from the composed body. Normal outgoing bubbles use the persisted
/// chatPreviewText and do not need this body-vs-loaded-text comparison.
enum LegacyOutgoingBodyTextFallback {
    static func preferredBodyText(
        _ outgoingBodyText: String?,
        over loadedText: String?
    ) -> String? {
        guard let outgoingBodyText,
              let candidate = comparableText(outgoingBodyText) else {
            return nil
        }

        guard let comparison = comparableText(loadedText) else {
            return outgoingBodyText
        }

        guard isRicher(candidate, than: comparison) else {
            return nil
        }

        return outgoingBodyText
    }

    private static func isRicher(_ candidate: ComparableText, than comparison: ComparableText) -> Bool {
        guard candidate.normalizedText.hasPrefix(comparison.normalizedText) else {
            return false
        }
        return candidate.tokenCount > comparison.tokenCount ||
            candidate.characterCount > comparison.characterCount
    }

    private static func comparableText(_ text: String?) -> ComparableText? {
        guard let text else { return nil }

        let normalizedText = HTMLEntityDecoder.decode(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        guard !normalizedText.isEmpty else {
            return nil
        }

        let tokenCount = normalizedText.split(separator: " ").count
        return ComparableText(
            normalizedText: normalizedText,
            tokenCount: tokenCount,
            characterCount: normalizedText.count
        )
    }

    private struct ComparableText {
        let normalizedText: String
        let tokenCount: Int
        let characterCount: Int
    }
}
