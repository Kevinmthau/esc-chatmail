import CryptoKit
import Foundation

// Cache-key derivation and source mapping — pure, instance-state-free helpers
// that turn a load request into stable NSCache keys. cacheVariantKey captures
// the display variant (plus evaluator inputs for the automatic original view);
// cacheKey folds in the resolved source and its content signature; the SHA256
// fingerprint / signature helpers and the source-enum mappings back them.
extension HTMLContentLoader {

    func cacheVariantKey(
        messageId: String,
        plainText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode,
        displayPurpose: HTMLDisplayPurpose,
        originalHTMLPreference: OriginalEmailHTMLPreference
    ) -> NSString {
        let evaluatorInputsKey: String
        if displayPurpose == .original, originalHTMLPreference == .automatic {
            evaluatorInputsKey = [
                cacheFingerprint(for: plainText),
                cacheFingerprint(for: subject),
                cacheFingerprint(for: senderEmail)
            ].joined(separator: "_")
        } else {
            evaluatorInputsKey = "static"
        }

        let appearanceKey = displayPurpose == .original ? "forcedLight" : "\(isDarkMode)"
        return "\(messageId)_\(appearanceKey)_\(cleanupMode.rawValue)_\(displayPurpose.rawValue)_\(originalHTMLPreference.rawValue)_\(evaluatorInputsKey)" as NSString
    }

    func cacheKey(
        variantKey: NSString,
        source: HTMLLoadResult.HTMLLoadSource,
        sourceSignature: String
    ) -> NSString {
        "\(variantKey)_\(cacheComponent(for: source))_\(sourceSignature)" as NSString
    }

    private func cacheFingerprint(for text: String?) -> String {
        guard let text = text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return "nil"
        }

        return SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func sourceSignature(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    private func cacheComponent(for source: HTMLLoadResult.HTMLLoadSource) -> String {
        switch source {
        case .messageId:
            return "messageId"
        case .storageURI:
            return "storageURI"
        case .rawSourceHTML:
            return "rawSourceHTML"
        case .recovered:
            return "recovered"
        case .qualityFallback:
            return "qualityFallback"
        case .plainTextFallback:
            return "plainTextFallback"
        case .notFound:
            return "notFound"
        }
    }

    func htmlLoadSource(
        for sourceLocation: CanonicalEmailSourceLocation
    ) -> HTMLLoadResult.HTMLLoadSource {
        switch sourceLocation {
        case .messageFile:
            return .messageId
        case .storageURI:
            return .storageURI
        case .rawSourceHTML:
            return .rawSourceHTML
        case .recoveredHTML:
            return .recovered
        case .plainText:
            return .plainTextFallback
        }
    }
}
