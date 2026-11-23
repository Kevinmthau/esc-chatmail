import Foundation

/// Why a body was not handed to the app's DOM code.
enum EmailDOMParseRefusal: LocalizedError, Equatable {
    /// The tree is, or may be, deeper than
    /// `EmailDOMParseAdmission.maximumDepth`: `depth` is SwiftSoup's measured
    /// depth, or the byte scan's bound where that was too high to parse at
    /// all. The HTML itself may be fine to show; only the DOM work was
    /// declined.
    case nestingTooDeep(depth: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .nestingTooDeep(depth, limit):
            "HTML nesting depth \(depth) exceeds the parse limit \(limit)."
        }
    }
}
