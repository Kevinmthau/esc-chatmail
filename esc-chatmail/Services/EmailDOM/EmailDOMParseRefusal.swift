import Foundation

/// Why a body was not handed to the app's DOM code.
enum EmailDOMParseRefusal: LocalizedError, Equatable {
    /// The tree is, or may be, deeper than
    /// `EmailDOMParseAdmission.maximumDepth`: `depth` is SwiftSoup's measured
    /// depth, or the byte scan's bound where that was too high to parse at
    /// all. The HTML itself may be fine to show; only the DOM work was
    /// declined.
    case nestingTooDeep(depth: Int, limit: Int)
    /// The byte scan's estimate of SwiftSoup's work for this body is past
    /// `limit`, so it was not parsed. SwiftSoup's parse is not linear in
    /// every input (`EmailDOMParseAdmission.ParseCost`); the body may be
    /// shallow.
    case tooCostlyToParse(work: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .nestingTooDeep(depth, limit):
            "HTML nesting depth \(depth) exceeds the parse limit \(limit)."
        case let .tooCostlyToParse(work, limit):
            "HTML parse work estimate \(work) exceeds the limit \(limit)."
        }
    }
}
