import Foundation

/// Priority level for fetch operations
enum FetchPriority: Int, Comparable, Sendable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    static func < (lhs: FetchPriority, rhs: FetchPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
