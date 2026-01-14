import Foundation

/// Centralizes display name formatting for conversations and participant lists.
/// Use this instead of duplicating formatting logic across services.
enum DisplayNameFormatter {

    // MARK: - Conversation Display (uses "&" separator)

    /// Formats names for conversation display using "&" as the final separator.
    /// - Parameter names: Full names or emails to format
    /// - Returns: Formatted string like "John Smith" (single) or "John & Jane" (group)
    ///
    /// Examples:
    /// - [] → ""
    /// - ["John Smith"] → "John Smith" (full name for single participant)
    /// - ["Rally House"] → "Rally House" (preserves company names)
    /// - ["John Smith", "Jane Doe"] → "John & Jane"
    /// - ["John", "Jane", "Bob"] → "John, Jane & Bob"
    /// - ["John", "Jane", "Bob", "Alice"] → "John, Jane, Bob & Alice"
    static func formatGroupNames(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return ""
        case 1:
            // Single participant: use full name (preserves company names like "Rally House")
            return names[0]
        default:
            // Multiple participants: use first names only (Apple-style for groups)
            let firstNames = names.map { extractFirstName($0) }
            switch firstNames.count {
            case 2:
                return "\(firstNames[0]) & \(firstNames[1])"
            case 3:
                return "\(firstNames[0]), \(firstNames[1]) & \(firstNames[2])"
            default:
                // 4 or more: "John, Jane, Bob & Alice"
                let allButLast = firstNames.dropLast()
                guard let last = firstNames.last else {
                    return allButLast.joined(separator: ", ")
                }
                return "\(allButLast.joined(separator: ", ")) & \(last)"
            }
        }
    }

    // MARK: - Row Display (uses "+" for overflow)

    /// Formats names for conversation row display with overflow indicator.
    /// Single participants show full names; groups show first names only (Apple-style).
    /// - Parameters:
    ///   - names: Visible participant names
    ///   - totalCount: Total number of participants
    ///   - fallback: Fallback display name if names is empty
    /// - Returns: Formatted string like "John Smith" (single) or "John, Jane +3" (group)
    ///
    /// Examples:
    /// - ([], 0, "Unknown") → "Unknown"
    /// - (["John Smith"], 1, nil) → "John Smith"
    /// - (["John Smith", "Jane Doe"], 2, nil) → "John, Jane"
    /// - (["John Smith", "Jane Doe"], 5, nil) → "John, Jane +3"
    static func formatForRow(names: [String], totalCount: Int, fallback: String?) -> String {
        guard !names.isEmpty else {
            return fallback ?? "No participants"
        }

        switch names.count {
        case 1:
            // Single participant: show full name
            return names[0]
        default:
            // Multiple participants: use first names only (Apple-style)
            // Show up to 4 names to fill available space
            let firstNames = names.map { extractFirstName($0) }
            let maxVisible = min(firstNames.count, 4)
            let visibleNames = firstNames.prefix(maxVisible).joined(separator: ", ")
            let remaining = totalCount - maxVisible
            if remaining > 0 {
                return "\(visibleNames) +\(remaining)"
            } else {
                return visibleNames
            }
        }
    }

    // MARK: - Private Helpers

    /// Extracts the first name from a full name string.
    /// - Parameter name: Full name like "John Smith" or email like "john@example.com"
    /// - Returns: First non-empty component before space, or the trimmed string if no space.
    ///           Includes "Dr." prefix when present (e.g., "Dr. John Smith" → "Dr. John")
    private static func extractFirstName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let components = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }

        guard !components.isEmpty else { return trimmed }

        // Check if first component is "Dr." or "Dr" - include it with the first name
        let first = components[0]
        if (first == "Dr." || first == "Dr") && components.count > 1 {
            return "\(first) \(components[1])"
        }

        return first
    }
}
