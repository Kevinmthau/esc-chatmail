import SwiftSoup

extension Element {
    /// SwiftSoup's `tagName()` may return capitalized values for SVG / XML
    /// elements; lowercasing once at the call site keeps comparisons cheap.
    ///
    /// Shared by the EmailDOM parsing/quote-removal passes. Previously duplicated
    /// as an identical `private` helper in `EmailDOMQuoteRemover` and
    /// `EmailDOMTextExtractor`; consolidated here so the quote-remover can be
    /// split across files without re-duplicating it.
    func tagNameNormal() -> String {
        tagName().lowercased()
    }
}
