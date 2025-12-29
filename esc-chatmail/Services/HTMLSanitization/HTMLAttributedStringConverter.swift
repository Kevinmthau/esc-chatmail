import UIKit

/// Converts HTML to NSAttributedString for simple content
struct HTMLAttributedStringConverter {
    /// Converts sanitized HTML to attributed string if content is simple enough
    /// - Parameters:
    ///   - html: Sanitized HTML string
    ///   - isFromMe: Whether the message is from the current user (affects colors)
    /// - Returns: NSAttributedString if conversion succeeds, nil otherwise
    func convert(_ html: String, isFromMe: Bool) -> NSAttributedString? {
        // Check if HTML is simple enough for AttributedString
        guard isSimpleHTML(html) else { return nil }
        return convertToAttributedString(html, isFromMe: isFromMe)
    }

    /// Checks if HTML only contains simple formatting tags
    func isSimpleHTML(_ html: String) -> Bool {
        let complexPatterns = [
            "<table", "<img", "<video", "<audio", "<iframe",
            "<form", "<input", "<canvas", "<svg"
        ]

        let lowercased = html.lowercased()
        for pattern in complexPatterns {
            if lowercased.contains(pattern) {
                return false
            }
        }

        return true
    }

    private func convertToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        do {
            let attributed = try NSMutableAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            )

            // Apply theme colors
            let textColor = isFromMe ? UIColor.white : UIColor.label
            let linkColor = isFromMe ? UIColor(red: 0.68, green: 0.85, blue: 0.9, alpha: 1.0) : UIColor.systemBlue

            attributed.addAttributes([
                .foregroundColor: textColor,
                .font: UIFont.systemFont(ofSize: 16)
            ], range: NSRange(location: 0, length: attributed.length))

            // Update link colors
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                if value != nil {
                    attributed.addAttribute(.foregroundColor, value: linkColor, range: range)
                }
            }

            return attributed
        } catch {
            return nil
        }
    }
}
