import CoreGraphics
import Foundation

/// Estimates HTML email layout width and computes a safe preview scale that avoids horizontal clipping.
enum HTMLPreviewScaleCalculator {
    private static let minCandidateWidth = 280
    private static let maxCandidateWidth = 2000
    private static let minimumScale: CGFloat = 0.2
    private static let widthSafetyPadding: CGFloat = 24

    static func previewScale(defaultScale: CGFloat, containerWidth: CGFloat, html: String) -> CGFloat {
        let clampedDefault = max(minimumScale, min(defaultScale, 1.0))

        guard containerWidth > 0,
              let estimatedWidth = estimatedLayoutWidth(from: html),
              estimatedWidth > 0 else {
            return clampedDefault
        }

        // Reserve a small margin for wrapper/body padding and rounding differences.
        let fitScale = containerWidth / (estimatedWidth + widthSafetyPadding)
        return max(minimumScale, min(clampedDefault, fitScale))
    }

    static func estimatedLayoutWidth(from html: String) -> CGFloat? {
        let normalizedHTML = normalizedForWidthDetection(html)

        let minWidth = largestMatch(
            in: normalizedHTML,
            pattern: #"min-width\s*:\s*([0-9]{2,4})\s*px"#
        )
        let tableWidth = largestMatch(
            in: normalizedHTML,
            pattern: #"<table[^>]*?\bwidth\s*=\s*["']?([0-9]{2,4})"#
        )
        let cssWidth = largestMatch(
            in: normalizedHTML,
            pattern: #"width\s*:\s*([0-9]{2,4})\s*px"#
        )

        let maxCandidate = [minWidth, tableWidth, cssWidth].compactMap { $0 }.max()
        return maxCandidate.map { CGFloat($0) }
    }

    private static func largestMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let values = regex.matches(in: text, options: [], range: range).compactMap { match -> Int? in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text),
                  let width = Int(text[valueRange]),
                  width >= minCandidateWidth,
                  width <= maxCandidateWidth else {
                return nil
            }
            return width
        }

        return values.max()
    }

    private static func normalizedForWidthDetection(_ html: String) -> String {
        html
            // Quoted-printable soft line breaks
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
            // Common quoted-printable encoding for '=' in attributes
            .replacingOccurrences(of: "=3D", with: "=", options: .caseInsensitive)
    }
}
