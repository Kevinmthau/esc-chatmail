import Foundation

/// Email validation utility
/// Extracted from RecipientField for reuse across the app
enum EmailValidator {
    /// Standard email regex pattern
    private static let pattern = #"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"#

    /// Compiled regex for performance (created once)
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Validates an email address format
    /// - Parameter email: The email address to validate
    /// - Returns: true if the email format is valid
    static func isValid(_ email: String) -> Bool {
        guard let regex = regex else { return false }
        let range = NSRange(location: 0, length: email.utf16.count)
        return regex.firstMatch(in: email, options: [], range: range) != nil
    }
}
