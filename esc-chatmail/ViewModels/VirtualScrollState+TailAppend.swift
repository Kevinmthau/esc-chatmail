import Foundation
import CoreData

// MARK: - Local-send tail append

extension VirtualScrollState {
    /// The user's own just-sent rows that `handleViewContextChange` may append
    /// to the window in place, or nil when the change must take the full
    /// latest-window reload.
    ///
    /// Why it exists: the optimistic save posts objectsDidChange on the
    /// viewContext in the same turn as the send, but the full path answered it
    /// with a reconcile task that re-counted the conversation on the main queue
    /// and re-fetched and re-mapped every row of the window (up to
    /// `maxWindowSize`) — several main-queue turns plus a superseded load before
    /// the bubble existed, all landing on the frame the reply should appear in.
    /// The fast path maps only the new rows, from the objects the notification
    /// already delivered, and publishes them in the same turn.
    ///
    /// Deliberately narrow; every other change keeps the full reload, which is
    /// also the healing path for rows changed without a precise notification
    /// (so cached rows are reused only here, not wholesale). It requires:
    /// - no load in flight (a load owns the user's current scroll intent) and a
    ///   loaded initial window;
    /// - a window that follows the latest messages and genuinely abuts the
    ///   tail: the count is not stale (`window.endIndex == totalMessageCount`,
    ///   no unpublished pending insertions, no unclassified-refresh count
    ///   reconciliation outstanding);
    /// - an insertion-only change — the caller rules out deletions, ordered
    ///   updates, and ambiguous refreshes;
    /// - every visible inserted message of this conversation is a local
    ///   optimistic send (`OutboundSendDeliveryState.localOptimisticMessageID`)
    ///   with a permanent ID that sorts strictly after the window's last row.
    ///   Sync inserts (incoming mail, the send's own echo) keep the reload.
    ///
    /// Returns the messages in dataset order (`internalDate`, then `id`).
    func localSendTailAppendMessages(
        in notification: Notification,
        window: MessageWindow,
        knownTotalCount: Int
    ) -> [Message]? {
        guard windowLoadLifecycle == .idle,
              initialLoadPhase == .loaded,
              shouldFollowLatestWindow(window),
              pendingInsertedMessageEvents.isEmpty,
              window.endIndex == totalMessageCount,
              window.messageIDs.count == window.endIndex - window.startIndex,
              !needsUnclassifiedRefreshCountReconciliation,
              let boundaryMessageID = window.messageIDs.last,
              let boundaryRow = resolveCachedRow(for: boundaryMessageID) else {
            return nil
        }

        let insertedMessages = contextObjects(
            forKeys: [NSInsertedObjectsKey],
            in: notification
        ).compactMap { object -> Message? in
            guard let message = object as? Message,
                  belongsToCurrentConversation(message),
                  isVisibleInChat(message) else {
                return nil
            }
            return message
        }
        guard !insertedMessages.isEmpty,
              knownTotalCount == totalMessageCount + insertedMessages.count else {
            return nil
        }

        let windowMessageIDs = Set(window.messageIDs)
        for message in insertedMessages {
            guard !message.isDeleted,
                  !message.objectID.isTemporaryID,
                  !windowMessageIDs.contains(message.objectID),
                  OutboundSendDeliveryState.localOptimisticMessageID(for: message) != nil,
                  compareSortOrder(message, to: boundaryRow) == .orderedDescending else {
                return nil
            }
        }

        // The page loaders sort by `internalDate` then `id`; `compare` matches
        // the store's ordering for the ASCII identifiers rows carry.
        return insertedMessages.sorted { lhs, rhs in
            if lhs.internalDate != rhs.internalDate {
                return lhs.internalDate < rhs.internalDate
            }
            return lhs.id.compare(rhs.id) == .orderedAscending
        }
    }

    /// Appends `messages` (from `localSendTailAppendMessages`) to `window` and
    /// publishes the result in the caller's turn, mirroring what a latest
    /// reload would publish for the same change: the window keeps its
    /// accumulated rows (front-trimmed to the cap), the count and the window
    /// end agree — so the view's grouping lookahead never runs its body-time
    /// offset fetch for an unpublished tail row — and the pending
    /// inserted-message events resolve against the new layout for the
    /// auto-read pipeline. Rows invalidated by this same notification are
    /// re-mapped by `resolveCachedRows`; the rest are the window's own rows,
    /// which `handleViewContextChange` keeps fresh.
    func publishLocalSendTailAppend(
        _ messages: [Message],
        to window: MessageWindow
    ) {
        let appendedRows = ChatMessageRowModelMapper.map(messages)
        let appendedMessageIDs = messages.map(\.objectID)
        let extendedWindow = MessageWindow(
            startIndex: window.startIndex,
            endIndex: window.endIndex + appendedMessageIDs.count,
            messageIDs: window.messageIDs + appendedMessageIDs,
            isLoading: false
        ).frontTrimmed(to: configuration.maxWindowSize)

        setMessageWindow(extendedWindow)
        for (objectID, row) in zip(appendedMessageIDs, appendedRows) {
            resolvedRowsByID[objectID] = row
        }
        // `handleViewContextChange` already raised the count to this value;
        // the guard only avoids a redundant publish.
        if totalMessageCount != extendedWindow.endIndex {
            totalMessageCount = extendedWindow.endIndex
        }
        if scrollPosition < extendedWindow.startIndex {
            // A trim moved the head past the tracked position; park it at the
            // head like a latest reload does (`loadLatestWindow`).
            scrollPosition = extendedWindow.startIndex
        }
        // After `setMessageWindow`, which clears the previous send's set.
        localSendAppendedMessageIDs = Set(appendedMessageIDs)
        visibleMessages = resolveCachedRows(for: extendedWindow.messageIDs)
        resolvePendingInsertedMessageEvents()
        schedulePostSyncDatasetReconciliationIfNeeded()
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll local send appended in place conv=\(conversationId) appended=\(appendedMessageIDs.count) window=\(extendedWindow.startIndex)..<\(extendedWindow.endIndex)",
            category: .ui
        )
    }
}
