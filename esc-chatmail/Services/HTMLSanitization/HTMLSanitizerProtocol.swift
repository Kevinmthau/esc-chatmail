import Foundation

/// Protocol defining HTML sanitization capabilities
protocol HTMLSanitizerProtocol {
    func sanitize(_ html: String) -> String
    func htmlToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString?
    func analyzeComplexity(_ html: String) -> HTMLComplexity
}

/// Indicates the rendering complexity of HTML content
enum HTMLComplexity {
    /// Can be rendered using AttributedString
    case simple
    /// Needs WebView but can use optimizations
    case moderate
    /// Requires full WebView rendering
    case complex
}
