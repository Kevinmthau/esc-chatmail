import Foundation

/// Represents a quoted section extracted from an email
struct QuotedPart: Sendable, Equatable {
    /// The quoted text content
    let text: String

    /// Attribution line (e.g., "On Jan 1, 2024, John wrote:")
    let attribution: String?

    /// Nesting level (0 = top-level quote, 1 = quote within quote, etc.)
    let nestingLevel: Int

    init(text: String, attribution: String? = nil, nestingLevel: Int = 0) {
        self.text = text
        self.attribution = attribution
        self.nestingLevel = nestingLevel
    }
}

/// Result of quote extraction containing both the main content and extracted quotes
struct QuoteExtractionResult: Sendable {
    /// The main message content with quotes removed
    let mainContent: String

    /// Extracted quoted parts, in order of appearance
    let quotedParts: [QuotedPart]

    /// Total number of quoted parts
    var quoteCount: Int { quotedParts.count }

    /// Whether any quotes were extracted
    var hasQuotes: Bool { !quotedParts.isEmpty }
}
