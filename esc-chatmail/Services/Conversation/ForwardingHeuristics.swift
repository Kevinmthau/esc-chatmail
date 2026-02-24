import Foundation

/// Shared heuristics for detecting forwarded-message branches that should
/// remain participant-based instead of being collapsed by Gmail thread ID.
enum ForwardingHeuristics {
    private static let subjectPrefixes = ["fwd:", "fw:"]

    // Match explicit forward/original markers with common client variants.
    private static let forwardMarkerPatterns: [NSRegularExpression] = [
        "(?:^|\\n|\\r|>)\\s*begin\\s+forwarded\\s+message\\b",
        "(?:^|\\n|\\r|>)\\s*-{2,}\\s*forwarded\\s+message\\b",
        "(?:^|\\n|\\r|>)\\s*-{2,}\\s*original\\s+message\\b",
        "(?:^|\\n|\\r|>)\\s*---\\s*original\\s+message\\s*---"
    ].compactMap { pattern in
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let internationalForwardMarkers: [String] = [
        "weitergeleitete nachricht",
        "message transféré",
        "mensaje reenviado",
        "messaggio inoltrato",
        "mensagem encaminhada",
        "doorgestuurd bericht"
    ]

    static func indicatesForwarding(subject: String?, contentCandidates: [String?]) -> Bool {
        if isForwardedSubject(subject) {
            return true
        }

        for candidate in contentCandidates where containsForwardMarker(in: candidate) {
            return true
        }

        return false
    }

    static func isForwardedSubject(_ subject: String?) -> Bool {
        guard let normalizedSubject = subject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalizedSubject.isEmpty else {
            return false
        }

        return subjectPrefixes.contains(where: { normalizedSubject.hasPrefix($0) })
    }

    private static func containsForwardMarker(in text: String?) -> Bool {
        guard let text = text, !text.isEmpty else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if forwardMarkerPatterns.contains(where: { $0.firstMatch(in: text, options: [], range: range) != nil }) {
            return true
        }

        let lowercased = text.lowercased()
        return internationalForwardMarkers.contains(where: { lowercased.contains($0) })
    }
}
