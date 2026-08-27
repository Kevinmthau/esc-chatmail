import Foundation
import CoreData
import Combine

// MARK: - Core Data change observation and classification

extension VirtualScrollState {
    func startObservingViewContextChanges() {
        if viewContextChangesCancellable == nil {
            viewContextChangesCancellable = NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: viewContext
            )
            .sink { [weak self] notification in
                self?.handleViewContextChange(notification)
            }
        }

        if syncCompletedCancellable == nil {
            syncCompletedCancellable = NotificationCenter.default.publisher(
                for: .syncCompleted
            )
            .sink { [weak self] _ in
                self?.schedulePostSyncDatasetReconciliationIfNeeded(
                    syncDidComplete: true
                )
            }
        }
    }

    private func handleViewContextChange(_ notification: Notification) {
        // objectsDidChange fires for every merged sync save while a chat is
        // open. Bail out on type checks alone before any pass below faults
        // objects: only Message/Attachment changes, outbound delivery markers,
        // and Person display-name updates can affect this window.
        guard Self.isRelevantChatContextChange(notification.userInfo) else { return }

        let insertedMessageIDs = visibleInsertedMessageIDsForCurrentConversation(
            in: notification
        )
        let hasVisibleInsertion = hasVisibleInsertedMessageForCurrentConversation(
            in: notification
        )
        let deletedMessages = contextObjects(
            forKeys: [NSDeletedObjectsKey],
            in: notification
        ).compactMap { $0 as? Message }
        let deletedMessageIDs = Set(deletedMessages.map(\.objectID))
        let hasCurrentConversationDeletion = deletedMessages.contains {
            belongsToCurrentConversation($0)
        }
        let hasDeletedWindowMessage = messageWindow.map {
            !Set($0.messageIDs).isDisjoint(with: deletedMessageIDs)
        } ?? false
        let uncachedRefreshAssessment = assessUncachedRefreshedMessages(
            in: notification
        )
        let hasOrderedDatasetUpdate = containsOrderedDatasetAffectingMessageUpdate(
            notification
        )
        let orderedDatasetDidChange =
            hasVisibleInsertion ||
            hasCurrentConversationDeletion ||
            hasDeletedWindowMessage ||
            hasOrderedDatasetUpdate ||
            uncachedRefreshAssessment.orderedDatasetDidChange

        if uncachedRefreshAssessment.needsCountReconciliation {
            needsUnclassifiedRefreshCountReconciliation = true
        }
        if orderedDatasetDidChange {
            messageDatasetGeneration &+= 1
        }
        guard let window = messageWindow else { return }

        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)
        let canPreserveHistoricalWindowForTailInsertion =
            !shouldFollowLatestWindow &&
            hasVisibleInsertion &&
            !hasCurrentConversationDeletion &&
            !hasDeletedWindowMessage &&
            !hasOrderedDatasetUpdate &&
            visibleInsertedMessagesSortStrictlyAfterWindow(
                in: notification,
                window: window
            )
        let requiresWindowReconciliation =
            orderedDatasetDidChange &&
            !canPreserveHistoricalWindowForTailInsertion
        let knownTotalCount = estimatedTotalCountAfterLocalMessageMutation(in: notification)
        if !insertedMessageIDs.isEmpty {
            let event = VirtualScrollInsertedMessageEvent(
                id: UUID(),
                messageIDs: insertedMessageIDs
            )
            insertedVisibleMessageEvents.send(event)
            if shouldFollowLatestWindow {
                let autoReadMessageIDs = newestVisibleInsertedMessageIDsForCurrentConversation(
                    in: notification
                )
                pendingInsertedMessageEvents.append(
                    VirtualScrollInsertedMessageEvent(
                        id: event.id,
                        messageIDs: autoReadMessageIDs
                    )
                )
            }
        }

        if knownTotalCount > totalMessageCount {
            resolvedRowsByAbsoluteIndex.removeAll()
            totalMessageCount = knownTotalCount
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll local message mutation count updated conv=\(conversationId) knownTotal=\(knownTotalCount)",
                category: .ui
            )
        }

        let boundaryMessageIDs = Set(resolvedRowsByAbsoluteIndex.values.map(\.objectID))
        let cachedMessageIDs = Set(window.messageIDs).union(boundaryMessageIDs)
        let affectedMessageIDs = cachedMessageIDs.isEmpty
            ? []
            : refreshedCachedMessageIDs(
                in: notification,
                cachedMessageIDs: cachedMessageIDs
            )

        let didInvalidateBoundaryRow = !boundaryMessageIDs.isDisjoint(
            with: affectedMessageIDs
        )
        invalidateCachedRows(for: affectedMessageIDs)

        if requiresWindowReconciliation {
            // An in-flight range/latest load owns the user's current scroll
            // intent. Its dataset token forces a bounded retry, so starting a
            // second reconciliation here would only invalidate that retry.
            if !isLoadingMore {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "VirtualScroll dataset reconciliation requested conv=\(conversationId) followsLatest=\(shouldFollowLatestWindow) knownTotal=\(knownTotalCount)",
                    category: .ui
                )
                taskManager.run(datasetReconcileTaskKey) { [weak self] in
                    guard let self else { return }
                    await self.reconcileWindowAfterDatasetMutation(
                        window: window,
                        shouldFollowLatestWindow: shouldFollowLatestWindow
                    )
                }
            } else {
                needsDatasetReconciliationAfterCurrentLoad = true
            }
            scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
            return
        }

        if !affectedMessageIDs.isEmpty {
            let refreshedRows = resolveCachedRows(for: window.messageIDs)
            if didInvalidateBoundaryRow || refreshedRows != visibleMessages {
                visibleMessages = refreshedRows
            }
        }
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
    }

    private func refreshedCachedMessageIDs(
        in notification: Notification,
        cachedMessageIDs: Set<NSManagedObjectID>
    ) -> Set<NSManagedObjectID> {
        var affectedMessageIDs = Set<NSManagedObjectID>()

        for object in contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message,
                  cachedMessageIDs.contains(message.objectID) else {
                continue
            }

            affectedMessageIDs.insert(message.objectID)
        }

        for object in contextObjects(
            forKeys: [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSDeletedObjectsKey],
            in: notification
        ) {
            guard let attachment = object as? Attachment,
                  let messageID = attachment.message?.objectID,
                  cachedMessageIDs.contains(messageID) else {
                continue
            }

            affectedMessageIDs.insert(messageID)
        }

        let changedOutboundSendIDs = Set(contextObjects(
            forKeys: [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        ).compactMap { object in
            (object as? OutboundSendMutationRecord)?.id
        })
        if !changedOutboundSendIDs.isEmpty {
            for messageID in cachedMessageIDs {
                guard let row = resolveCachedRow(for: messageID),
                      changedOutboundSendIDs.contains(row.id) else {
                    continue
                }
                affectedMessageIDs.insert(messageID)
            }
        }

        let changedPersonEmails = Set(contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        ).compactMap { object -> String? in
            guard let person = object as? Person else { return nil }
            let email = EmailNormalizer.normalize(person.email)
            return email.isEmpty ? nil : email
        })

        if !changedPersonEmails.isEmpty {
            for messageID in cachedMessageIDs {
                guard let row = resolveCachedRow(for: messageID),
                      row.matchesSenderEmail(in: changedPersonEmails) else {
                    continue
                }

                affectedMessageIDs.insert(messageID)
            }
        }

        return affectedMessageIDs
    }

    private func assessUncachedRefreshedMessages(
        in notification: Notification
    ) -> UncachedRefreshAssessment {
        var assessment = UncachedRefreshAssessment()

        for object in contextObjects(
            forKeys: [NSRefreshedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message else { continue }

            let cachedRow = resolvedRowsByID[message.objectID] ??
                resolvedRowsByAbsoluteIndex.values.first {
                    $0.objectID == message.objectID
                }
            guard cachedRow == nil else { continue }

            // A sibling-context merge does not retain changed property keys.
            // Delay ambiguous, off-window refreshes until count/sync
            // reconciliation instead of invalidating an in-flight initial load
            // for harmless changes such as marking old messages read.
            guard belongsToCurrentConversation(message) else { continue }

            if !isVisibleInChat(message) ||
                refreshedMessageCouldBelongInCurrentWindow(message) {
                assessment.orderedDatasetDidChange = true
            } else {
                assessment.needsCountReconciliation = true
            }
        }

        return assessment
    }

    private func refreshedMessageCouldBelongInCurrentWindow(
        _ message: Message
    ) -> Bool {
        guard let window = messageWindow,
              let firstMessageID = window.messageIDs.first,
              let lastMessageID = window.messageIDs.last,
              let firstRow = resolveCachedRow(for: firstMessageID),
              let lastRow = resolveCachedRow(for: lastMessageID) else {
            return false
        }

        if window.startIndex == 0,
           compareSortOrder(message, to: lastRow) != .orderedDescending {
            return true
        }
        if window.endIndex >= totalMessageCount,
           compareSortOrder(message, to: firstRow) != .orderedAscending {
            return true
        }
        return compareSortOrder(message, to: firstRow) != .orderedAscending &&
            compareSortOrder(message, to: lastRow) != .orderedDescending
    }

    private func compareSortOrder(
        _ message: Message,
        to row: ChatMessageRowModel
    ) -> ComparisonResult {
        if message.internalDate < row.internalDate {
            return .orderedAscending
        }
        if message.internalDate > row.internalDate {
            return .orderedDescending
        }
        return message.id.compare(row.id)
    }

    private func containsOrderedDatasetAffectingMessageUpdate(
        _ notification: Notification
    ) -> Bool {
        for object in contextObjects(
            forKeys: [NSUpdatedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message,
                  belongsToCurrentConversation(message) else {
                continue
            }

            let changedValues = message.changedValuesForCurrentEvent()
            let changedKeys = Set(changedValues.keys)
            if changedKeys.contains("conversation") ||
                changedKeys.contains("internalDate") {
                return true
            }
            if changedKeys.contains("labels") {
                guard let previousLabels = changedValues["labels"] as? NSSet else {
                    return true
                }

                let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
                let previousLabelIDs = Set(previousLabels.compactMap {
                    ($0 as? Label)?.id
                })
                guard previousLabelIDs.count == previousLabels.count else {
                    return true
                }

                let wasVisible = previousLabelIDs.isDisjoint(
                    with: excludedLabelIDs
                )
                if wasVisible != isVisibleInChat(message) {
                    return true
                }
            }
        }

        // Automatically merged sibling-context saves arrive as refreshed
        // objects with no property-key delta. Compare cached rows directly;
        // ambiguous uncached rows are classified separately so content-only
        // off-window updates do not invalidate the active fetch.
        for object in contextObjects(
            forKeys: [NSRefreshedObjectsKey],
            in: notification
        ) {
            guard let message = object as? Message else { continue }

            let cachedRow = resolvedRowsByID[message.objectID] ??
                resolvedRowsByAbsoluteIndex.values.first {
                    $0.objectID == message.objectID
                }
            let currentlyBelongs = belongsToCurrentConversation(message)

            guard currentlyBelongs || cachedRow != nil else { continue }
            guard let cachedRow else { continue }

            if cachedRow.conversationObjectID != message.conversation?.objectID ||
                cachedRow.internalDate != message.internalDate ||
                !isVisibleInChat(message) {
                return true
            }
        }

        return false
    }

    /// Type-check-only relevance scan for objectsDidChange payloads. Nothing
    /// here faults an object; the expensive relationship checks below only
    /// run for notifications that pass this.
    nonisolated static func isRelevantChatContextChange(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        let keys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSRefreshedObjectsKey,
            NSDeletedObjectsKey
        ]
        let personKeys: Set<String> = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]

        for key in keys {
            guard let objects = userInfo[key] as? Set<NSManagedObject> else { continue }
            let includesPersons = personKeys.contains(key)
            for object in objects {
                if object is Message ||
                    object is Attachment ||
                    object is OutboundSendMutationRecord {
                    return true
                }
                if includesPersons, object is Person {
                    return true
                }
            }
        }
        return false
    }

    /// Resolved once (objectID-only fetch) so conversation membership checks
    /// compare objectIDs instead of faulting each inserted message's
    /// Conversation row for its UUID. Temporary IDs (optimistic unsaved
    /// conversations) are not cached — they change identity on save.
    private func currentConversationObjectID() -> NSManagedObjectID? {
        if let cachedConversationObjectID {
            return cachedConversationObjectID
        }
        guard let conversationUUID = UUID(uuidString: conversationId) else { return nil }

        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
        request.predicate = NSPredicate(format: "id == %@", conversationUUID as CVarArg)
        request.resultType = .managedObjectIDResultType
        request.fetchLimit = 1

        let objectID = (try? viewContext.fetch(request))?.first
        if let objectID, !objectID.isTemporaryID {
            cachedConversationObjectID = objectID
        }
        return objectID
    }

    /// Membership check that faults at most the message row: the destination
    /// objectID of the to-one relationship is available without firing the
    /// Conversation's own fault (the previous UUID comparison loaded the
    /// Conversation row for every inserted message in every merge).
    private func belongsToCurrentConversation(_ message: Message) -> Bool {
        let conversationObjectID = currentConversationObjectID()
        let conversationUUID = UUID(uuidString: conversationId)

        if let messageConversation = message.conversation {
            if messageConversation.objectID == conversationObjectID {
                return true
            }
            // A sibling-context merge can publish the relationship before
            // all required attributes on its destination are materialized.
            // Reading the nonoptional Swift property in that window traps
            // while bridging nil; optional KVC keeps the observer resilient.
            if let messageConversationID =
                messageConversation.value(forKey: "id") as? UUID,
               messageConversationID == conversationUUID {
                return true
            }
        }

        // Core Data may clear an inverse relationship before publishing the
        // deleted object in objectsDidChange. Its committed destination still
        // identifies which conversation's ordered dataset changed.
        if let committedConversation = message.committedValues(
            forKeys: ["conversation"]
        )["conversation"] as? Conversation {
            if committedConversation.objectID == conversationObjectID {
                return true
            }
            if let committedConversationID =
                committedConversation.value(forKey: "id") as? UUID,
               committedConversationID == conversationUUID {
                return true
            }
        }

        return false
    }

    private func hasVisibleInsertedMessageForCurrentConversation(in notification: Notification) -> Bool {
        contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .contains { object in
                guard let message = object as? Message,
                      belongsToCurrentConversation(message) else {
                    return false
                }

                return isVisibleInChat(message)
            }
    }

    private func visibleInsertedMessagesSortStrictlyAfterWindow(
        in notification: Notification,
        window: MessageWindow
    ) -> Bool {
        guard let boundaryMessageID = window.messageIDs.last,
              let boundaryDate = resolveCachedRow(
                for: boundaryMessageID
              )?.internalDate else {
            return false
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

        return !insertedMessages.isEmpty &&
            insertedMessages.allSatisfy { $0.internalDate > boundaryDate }
    }

    private func estimatedTotalCountAfterLocalMessageMutation(in notification: Notification) -> Int {
        let insertedCount = visibleInsertedMessageCountForCurrentConversation(in: notification)
        let deletedCount = visibleDeletedMessageCountForCurrentConversation(in: notification)

        return max(0, totalMessageCount + insertedCount - deletedCount)
    }

    private func visibleInsertedMessageCountForCurrentConversation(in notification: Notification) -> Int {
        visibleInsertedMessageIDsForCurrentConversation(in: notification).count
    }

    private func visibleDeletedMessageCountForCurrentConversation(
        in notification: Notification
    ) -> Int {
        contextObjects(forKeys: [NSDeletedObjectsKey], in: notification)
            .compactMap { $0 as? Message }
            .filter {
                belongsToCurrentConversation($0) &&
                    wasVisibleInChatBeforeDeletion($0)
            }
            .count
    }

    private func wasVisibleInChatBeforeDeletion(_ message: Message) -> Bool {
        if let previousLabels = message.committedValues(
            forKeys: ["labels"]
        )["labels"] as? NSSet {
            let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
            let previousLabelIDs = Set(previousLabels.compactMap {
                ($0 as? Label)?.id
            })
            if previousLabelIDs.count == previousLabels.count {
                return previousLabelIDs.isDisjoint(with: excludedLabelIDs)
            }
        }

        return isVisibleInChat(message)
    }

    private func visibleInsertedMessageIDsForCurrentConversation(
        in notification: Notification
    ) -> [NSManagedObjectID] {
        contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .compactMap { object -> NSManagedObjectID? in
                guard let message = object as? Message,
                      !message.objectID.isTemporaryID,
                      belongsToCurrentConversation(message),
                      isVisibleInChat(message) else {
                    return nil
                }

                return message.objectID
            }
            .sorted {
                $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
            }
    }

    private func newestVisibleInsertedMessageIDsForCurrentConversation(
        in notification: Notification
    ) -> [NSManagedObjectID] {
        let latestWindowDate: Date?
        if let latestWindowMessageID = messageWindow?.messageIDs.last {
            guard let date = resolveCachedRow(for: latestWindowMessageID)?.internalDate else {
                return []
            }
            latestWindowDate = date
        } else {
            latestWindowDate = nil
        }

        return contextObjects(forKeys: [NSInsertedObjectsKey], in: notification)
            .compactMap { object -> NSManagedObjectID? in
                guard let message = object as? Message,
                      !message.objectID.isTemporaryID,
                      belongsToCurrentConversation(message),
                      isVisibleInChat(message),
                      latestWindowDate.map({ message.internalDate > $0 }) ?? true else {
                    return nil
                }

                return message.objectID
            }
            .sorted {
                $0.uriRepresentation().absoluteString < $1.uriRepresentation().absoluteString
            }
    }

    func resolvePendingInsertedMessageEvents() {
        guard !pendingInsertedMessageEvents.isEmpty else { return }

        let latestWindowMessageIDs: Set<NSManagedObjectID>
        if isShowingLatestWindow, let messageWindow {
            latestWindowMessageIDs = Set(messageWindow.messageIDs)
        } else {
            latestWindowMessageIDs = []
        }

        let events = pendingInsertedMessageEvents
        pendingInsertedMessageEvents.removeAll()
        let layoutID = UUID()
        latestWindowLayoutID = layoutID

        for event in events {
            refreshedInsertedMessageEvents.send(
                VirtualScrollInsertedMessageRefresh(
                    eventID: event.id,
                    layoutID: layoutID,
                    messageIDsInLatestWindow: event.messageIDs.filter {
                        latestWindowMessageIDs.contains($0)
                    }
                )
            )
        }
    }

    private func isVisibleInChat(_ message: Message) -> Bool {
        let excludedLabelIDs = Set(MessagePredicates.chatExcludedLabelIDs)
        let labelIDs = message.labels?.map(\.id) ?? []
        return labelIDs.allSatisfy { !excludedLabelIDs.contains($0) }
    }

    private func contextObjects(
        forKeys keys: [String],
        in notification: Notification
    ) -> Set<NSManagedObject> {
        keys.reduce(into: Set<NSManagedObject>()) { result, key in
            let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
            result.formUnion(objects)
        }
    }
}

private extension ChatMessageRowModel {
    func matchesSenderEmail(in emails: Set<String>) -> Bool {
        [
            senderInfoEmail,
            effectiveSenderEmail,
            senderEmail
        ]
        .compactMap { $0 }
        .map(EmailNormalizer.normalize)
        .contains { emails.contains($0) }
    }
}
