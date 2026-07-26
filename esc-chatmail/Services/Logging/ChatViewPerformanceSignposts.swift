import Foundation
import os.log

enum ChatViewPerformanceSignposts {
    struct Interval {
        fileprivate let id: OSSignpostID
    }

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.esc.inboxchat",
        category: .pointsOfInterest
    )

    static func beginInitialLoad(conversationID: String) -> Interval {
        let interval = Interval(id: OSSignpostID(log: log))
        os_signpost(
            .begin,
            log: log,
            name: "ChatInitialLoad",
            signpostID: interval.id,
            "conversation=%{public}@",
            conversationID
        )
        return interval
    }

    static func endInitialLoad(
        _ interval: Interval,
        conversationID: String,
        outcome: String,
        visibleRowCount: Int,
        totalCount: Int
    ) {
        os_signpost(
            .end,
            log: log,
            name: "ChatInitialLoad",
            signpostID: interval.id,
            "conversation=%{public}@ outcome=%{public}@ visible=%d total=%d",
            conversationID,
            outcome,
            visibleRowCount,
            totalCount
        )
    }

    static func firstRowsResolved(conversationID: String, count: Int) {
        os_signpost(
            .event,
            log: log,
            name: "ChatFirstRowsResolved",
            "conversation=%{public}@ count=%d",
            conversationID,
            count
        )
    }

    static func bottomAnchorVisible(conversationID: String) {
        os_signpost(
            .event,
            log: log,
            name: "ChatBottomAnchorVisible",
            "conversation=%{public}@",
            conversationID
        )
    }

    static func contentReady(conversationID: String) {
        os_signpost(
            .event,
            log: log,
            name: "ChatContentReady",
            "conversation=%{public}@",
            conversationID
        )
    }
}
