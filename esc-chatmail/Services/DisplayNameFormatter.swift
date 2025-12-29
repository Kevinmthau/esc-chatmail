import Foundation

/// Centralizes display name formatting for conversations and participant lists.
/// Use this instead of duplicating formatting logic across services.
enum DisplayNameFormatter {

    // MARK: - Conversation Display (uses "&" separator)

    /// Formats names for conversation display using "&" as the final separator.
    /// - Parameter names: Full names or emails to format
    /// - Returns: Formatted string like "John & Jane" or "John, Jane & Bob"
    ///
    /// Examples:
    /// - [] → ""
    /// - ["John Smith"] → "John"
    /// - ["John Smith", "Jane Doe"] → "John & Jane"
    /// - ["John", "Jane", "Bob"] → "John, Jane & Bob"
    /// - ["John", "Jane", "Bob", "Alice"] → "John, Jane, Bob & Alice"
    static func formatGroupNames(_ names: [String]) -> String {
        let firstNames = names.map { extractFirstName($0) }

        switch firstNames.count {
        case 0:
            return ""
        case 1:
            return firstNames[0]
        case 2:
            return "\(firstNames[0]) & \(firstNames[1])"
        case 3:
            return "\(firstNames[0]), \(firstNames[1]) & \(firstNames[2])"
        default:
            // 4 or more: "John, Jane, Bob & Alice"
            let allButLast = firstNames.dropLast()
            let last = firstNames.last!
            return "\(allButLast.joined(separator: ", ")) & \(last)"
        }
    }

    // MARK: - Row Display (uses "+" for overflow)

    /// Formats names for conversation row display with overflow indicator.
    /// - Parameters:
    ///   - names: Visible participant names (first names will be extracted)
    ///   - totalCount: Total number of participants
    ///   - fallback: Fallback display name if names is empty
    /// - Returns: Formatted string like "John, Jane +3"
    ///
    /// Examples:
    /// - ([], 0, "Unknown") → "Unknown"
    /// - (["John"], 1, nil) → "John"
    /// - (["John", "Jane"], 2, nil) → "John, Jane"
    /// - (["John", "Jane"], 5, nil) → "John, Jane +3"
    static func formatForRow(names: [String], totalCount: Int, fallback: String?) -> String {
        guard !names.isEmpty else {
            return fallback ?? "No participants"
        }

        let firstNames = names.map { extractFirstName($0) }

        switch firstNames.count {
        case 1:
            return firstNames[0]
        case 2:
            let remaining = totalCount - 2
            if remaining > 0 {
                return "\(firstNames[0]), \(firstNames[1]) +\(remaining)"
            } else {
                return "\(firstNames[0]), \(firstNames[1])"
            }
        default:
            let remaining = totalCount - 2
            if remaining > 0 {
                return "\(firstNames[0]), \(firstNames[1]) +\(remaining)"
            } else {
                return "\(firstNames[0]), \(firstNames[1])"
            }
        }
    }

    // MARK: - Private Helpers

    /// Extracts the first name from a full name string.
    /// - Parameter name: Full name like "John Smith" or email like "john@example.com"
    /// - Returns: First component before space, or the original string if no space
    private static func extractFirstName(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }
}
