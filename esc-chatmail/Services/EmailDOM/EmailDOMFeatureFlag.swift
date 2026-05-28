import Foundation

/// Runtime toggles for the DOM-based HTML processing pipeline.
///
/// The DOM-based pipeline is now the default for the migrated paths
/// (`HTMLQuoteRemover`, `TextProcessing.extractPlainText`, etc.). Setting a
/// flag to `NO` routes the corresponding call site back through the legacy
/// regex-based implementation.
///
/// Override at launch via standard `UserDefaults` keys, e.g. for a build
/// scheme argument: `-EmailDOM_All NO`.
enum EmailDOMFeatureFlag {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let all = "EmailDOM_All"
        static let quoteRemoval = "EmailDOM_QuoteRemoval"
        static let textExtraction = "EmailDOM_TextExtraction"
        static let inlineContentIDExtraction = "EmailDOM_InlineContentIDExtraction"
        static let htmlSanitization = "EmailDOM_HTMLSanitization"
    }

    /// When true, `EmailTextProcessor.removeQuotedFromHTML` and the bubble
    /// loader's HTML-analysis paths use `EmailDOMQuoteRemover`.
    static var useDOMQuoteRemoval: Bool {
        isEnabled(forKey: Key.quoteRemoval)
    }

    /// When true, `TextProcessing.extractPlainText` routes through the DOM
    /// extractor for HTML inputs.
    static var useDOMTextExtraction: Bool {
        isEnabled(forKey: Key.textExtraction)
    }

    /// When true, inline `cid:` content-ID enumeration uses the DOM walker
    /// rather than the legacy string-scan.
    static var useDOMInlineContentIDExtraction: Bool {
        isEnabled(forKey: Key.inlineContentIDExtraction)
    }

    /// When true, `HTMLSanitizerService` removes dangerous elements and event
    /// handler attributes through SwiftSoup before running the existing URL,
    /// tracking-pixel, and CSS sanitizers.
    static var useDOMHTMLSanitization: Bool {
        isEnabled(forKey: Key.htmlSanitization)
    }

    /// Explicit master enable. `EmailDOM_All = NO` is the legacy-pipeline
    /// rollback path, and absent means the DOM defaults remain in effect.
    static var useDOMPipelineAll: Bool {
        overrideValue(forKey: Key.all) == true
    }

    static func isQuoteRemovalEnabled() -> Bool {
        useDOMQuoteRemoval
    }

    static func isTextExtractionEnabled() -> Bool {
        useDOMTextExtraction
    }

    static func isInlineContentIDExtractionEnabled() -> Bool {
        useDOMInlineContentIDExtraction
    }

    static func isHTMLSanitizationEnabled() -> Bool {
        useDOMHTMLSanitization
    }

    private static func isEnabled(forKey componentKey: String) -> Bool {
        if let allOverride = overrideValue(forKey: Key.all) {
            return allOverride
        }

        return overrideValue(forKey: componentKey) ?? true
    }

    private static func overrideValue(forKey key: String) -> Bool? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }

        return defaults.bool(forKey: key)
    }
}
