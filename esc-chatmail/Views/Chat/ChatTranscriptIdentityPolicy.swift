import Foundation

/// Assigns each transcript row the SwiftUI identity its `ForEach` and `.id`
/// use: the row's `displayIdentity` (`ChatMessageDisplayIdentity`), made unique
/// across the collection.
///
/// An optimistic reply and its sync echo can render side by side: when the
/// echo's conversation route is unresolved, sync creates the echo but defers
/// consuming the optimistic row (`preserveSupersededOptimisticContentIfNeeded`
/// in `MessagePersister+Helpers`), possibly for several sync intervals. Both
/// rows then carry the same `.outboundSend` identity, and a duplicate `ForEach`
/// ID is undefined behavior. The echo keeps the shared identity, because it is
/// the row that survives: the view that showed the optimistic bubble refreshes
/// in place into the echo, and stays put when the optimistic row is finally
/// consumed. Each loser falls back to its own object ID, which is unique within
/// a window.
enum ChatTranscriptIdentityPolicy {
    struct Row: Identifiable {
        let id: ChatMessageDisplayIdentity
        /// Position in the published `visibleMessages`.
        let index: Int
        let message: ChatMessageRowModel
    }

    static func rows(for messages: [ChatMessageRowModel]) -> [Row] {
        var occurrences: [ChatMessageDisplayIdentity: Int] = [:]
        for message in messages {
            occurrences[message.displayIdentity, default: 0] += 1
        }
        guard occurrences.count < messages.count else {
            return messages.enumerated().map { index, message in
                Row(id: message.displayIdentity, index: index, message: message)
            }
        }

        // Winner per shared identity: the first row that is not awaiting its
        // echo (the echo, or a renamed optimistic row Gmail has confirmed);
        // the first row when every claimant is still optimistic.
        var winners: [ChatMessageDisplayIdentity: Int] = [:]
        for (index, message) in messages.enumerated()
        where occurrences[message.displayIdentity, default: 0] > 1 {
            let identity = message.displayIdentity
            guard let currentWinner = winners[identity] else {
                winners[identity] = index
                continue
            }
            if messages[currentWinner].isAwaitingSyncEcho && !message.isAwaitingSyncEcho {
                winners[identity] = index
            }
        }

        return messages.enumerated().map { index, message in
            let identity = message.displayIdentity
            if let winner = winners[identity], winner != index {
                return Row(id: .message(message.objectID), index: index, message: message)
            }
            return Row(id: identity, index: index, message: message)
        }
    }
}
