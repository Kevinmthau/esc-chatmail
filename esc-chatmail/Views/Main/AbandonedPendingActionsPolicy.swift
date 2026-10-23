import Foundation

/// Words the conversation list's banner for pending actions the queue gave up
/// on: changes the user made in the app (archive, Report Spam, read state,
/// star) that never reached Gmail.
enum AbandonedPendingActionsPolicy {
    struct Summary: Equatable {
        let title: String
        let detail: String
    }

    /// nil hides the banner. `actionDescriptions` holds one entry per
    /// abandoned action (`AbandonedActionInfo.actionDescription`); the detail
    /// names each kind once, in first-seen order.
    static func summary(forActionDescriptions actionDescriptions: [String]) -> Summary? {
        guard !actionDescriptions.isEmpty else { return nil }

        let count = actionDescriptions.count
        let title = count == 1
            ? "1 change didn't reach Gmail"
            : "\(count) changes didn't reach Gmail"

        var seen = Set<String>()
        let kinds = actionDescriptions.filter { seen.insert($0).inserted }
        return Summary(title: title, detail: kinds.joined(separator: ", "))
    }
}
