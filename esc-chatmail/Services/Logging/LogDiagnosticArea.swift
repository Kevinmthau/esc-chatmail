import Foundation

// MARK: - Diagnostic Log Areas

/// Opt-in diagnostic areas for especially noisy traces.
///
/// Enable with `ESC_LOG_DIAGNOSTICS`, for example:
/// `ESC_LOG_DIAGNOSTICS=startup,html-preview`
enum LogDiagnosticArea: String, CaseIterable, Hashable {
    case startup = "startup"
    case chatView = "chat-view"
    case htmlPreview = "html-preview"
    case pendingActions = "pending-actions"
    case conversationRollups = "conversation-rollups"

    static let environmentKey = "ESC_LOG_DIAGNOSTICS"

    static func parse(environmentValue: String?) -> Set<LogDiagnosticArea> {
        guard let environmentValue else { return [] }

        var parsedAreas = Set<LogDiagnosticArea>()

        for rawToken in environmentValue.split(separator: ",") {
            let token = rawToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")

            guard !token.isEmpty else { continue }

            if token == "all" {
                return Set(allCases)
            }

            if let area = LogDiagnosticArea(rawValue: token) {
                parsedAreas.insert(area)
            }
        }

        return parsedAreas
    }
}
