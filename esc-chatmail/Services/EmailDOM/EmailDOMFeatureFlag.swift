import Foundation

/// Runtime toggles for the DOM-based HTML processing pipeline.
///
/// The legacy regex-based pipeline (`HTMLQuoteRemover`,
/// `TextProcessing.extractPlainText`, etc.) remains the default. Setting any
/// flag below routes the corresponding call sites through the DOM-based
/// implementations in `EmailDOM/*`.
///
/// Override at launch via standard `UserDefaults` keys, e.g. for a build
/// scheme argument: `-EmailDOM_QuoteRemoval YES`.
enum EmailDOMFeatureFlag {
    private static let defaults = UserDefaults.standard

    /// When true, `EmailTextProcessor.removeQuotedFromHTML` and the bubble
    /// loader's HTML-analysis paths use `EmailDOMQuoteRemover` instead of
    /// `HTMLQuoteRemover`.
    static var useDOMQuoteRemoval: Bool {
        defaults.bool(forKey: "EmailDOM_QuoteRemoval")
    }

    /// When true, `TextProcessing.extractPlainText` routes through
    /// `EmailDOMTextExtractor` for HTML inputs.
    static var useDOMTextExtraction: Bool {
        defaults.bool(forKey: "EmailDOM_TextExtraction")
    }

    /// When true, inline `cid:` content-ID enumeration uses the DOM walker
    /// rather than the legacy string-scan.
    static var useDOMInlineContentIDExtraction: Bool {
        defaults.bool(forKey: "EmailDOM_InlineContentIDExtraction")
    }

    /// Master switch: enables all DOM-based paths in one go. Useful for
    /// QA passes and for the eventual default flip.
    static var useDOMPipelineAll: Bool {
        defaults.bool(forKey: "EmailDOM_All")
    }

    static func isQuoteRemovalEnabled() -> Bool {
        useDOMQuoteRemoval || useDOMPipelineAll
    }

    static func isTextExtractionEnabled() -> Bool {
        useDOMTextExtraction || useDOMPipelineAll
    }

    static func isInlineContentIDExtractionEnabled() -> Bool {
        useDOMInlineContentIDExtraction || useDOMPipelineAll
    }
}
