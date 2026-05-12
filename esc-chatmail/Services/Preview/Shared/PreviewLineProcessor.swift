import Foundation

struct PreviewLineProcessorConfig {
    let footerStopPatterns: [String]
    let truncationTrailingMinDistance: Int
}

struct PreviewLineProcessor {
    let config: PreviewLineProcessorConfig

    func shouldStopAtFooter(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return config.footerStopPatterns.contains { lowercased.contains($0) }
    }

    func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let truncated = String(text.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " "),
           truncated.distance(from: truncated.startIndex, to: lastSpace)
            > limit - config.truncationTrailingMinDistance {
            return String(truncated[..<lastSpace]) + "..."
        }

        return truncated + "..."
    }
}
