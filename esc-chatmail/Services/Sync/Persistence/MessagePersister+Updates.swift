import Foundation
import CoreData

// MARK: - Message Updates

private struct MessageUpdateResult {
    let didUpdate: Bool
    /// True when the existing-message lookup itself failed (Core Data error),
    /// as opposed to the message legitimately not being present. Callers must
    /// not fall through to creation on a failed lookup — that risks inserting
    /// a duplicate of a row that exists.
    var lookupFailed: Bool = false
    let modifiedConversationID: NSManagedObjectID?
    let reroutedFromConversationID: NSManagedObjectID?
    let shouldInvalidateRenderedContent: Bool
    let htmlSourceDidChange: Bool
    let changedHTMLSourceSignature: String?
    let participantDisplayNameUpdateEmails: [String]
    let participantDisplayNameUpdateConversationIDs: Set<NSManagedObjectID>
}

/// Three-way outcome of an existing-message update attempt.
enum ExistingMessageUpdateOutcome: Sendable {
    case updated
    case notPresent
    case lookupFailed
}

extension MessagePersister {

    /// Updates an existing message if it exists.
    /// - Returns: true if an existing message was found and updated
    func updateExistingMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String> = [],
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext
    ) async -> Bool {
        let remoteCommittedSendMutation: RemoteCommittedSendMutationResolution?
        do {
            remoteCommittedSendMutation = try await remoteCommittedSendMutationResolutions(
                for: [processedMessage.id],
                sentMessageIDsByRemoteID: Self.sentMessageIDsByRemoteID(
                    in: [processedMessage]
                ),
                in: context
            )[processedMessage.id]
        } catch {
            // A failed mutation lookup cannot be treated as "no route": doing
            // so could persist the echo and strand its optimistic graph forever.
            Log.error(
                "Failed to resolve remote committed send mutation",
                category: .coreData,
                error: error
            )
            return false
        }
        return await updateExistingMessage(
            processedMessage,
            labelIds: labelIds,
            myAliases: myAliases,
            modificationTransaction: modificationTransaction,
            remoteCommittedSendMutation: remoteCommittedSendMutation,
            in: context
        )
    }

    func updateExistingMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String>,
        modificationTransaction: ModificationTracker.Transaction?,
        remoteCommittedSendMutation: RemoteCommittedSendMutationResolution?,
        in context: NSManagedObjectContext
    ) async -> Bool {
        let outcome = await updateExistingMessageOutcome(
            processedMessage,
            labelIds: labelIds,
            myAliases: myAliases,
            modificationTransaction: modificationTransaction,
            reroutedSourceRollupBuffer: nil,
            remoteCommittedSendMutation: remoteCommittedSendMutation,
            in: context
        )
        return outcome == .updated
    }

    /// Truthful update attempt: distinguishes "not local yet" (safe to
    /// create) from "the lookup failed" (must not create — the row may exist).
    /// Pass a `reroutedSourceRollupBuffer` on the batch path so rerouted
    /// sources are registered synchronously with the invocation-local buffer
    /// inside the relationship-move block.
    func updateExistingMessageOutcome(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String>,
        modificationTransaction: ModificationTracker.Transaction?,
        reroutedSourceRollupBuffer: MessagePersisterReroutedSourceRollupBuffer?,
        remoteCommittedSendMutation: RemoteCommittedSendMutationResolution?,
        in context: NSManagedObjectContext
    ) async -> ExistingMessageUpdateOutcome {
        let result = await performExistingMessageUpdate(
            processedMessage,
            labelIds: labelIds,
            myAliases: myAliases,
            modificationTransaction: modificationTransaction,
            reroutedSourceRollupBuffer: reroutedSourceRollupBuffer,
            remoteCommittedSendMutation: remoteCommittedSendMutation,
            in: context
        )
        if result.didUpdate { return .updated }
        return result.lookupFailed ? .lookupFailed : .notPresent
    }

    private func performExistingMessageUpdate(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String>,
        modificationTransaction: ModificationTracker.Transaction?,
        reroutedSourceRollupBuffer: MessagePersisterReroutedSourceRollupBuffer?,
        remoteCommittedSendMutation: RemoteCommittedSendMutationResolution?,
        in context: NSManagedObjectContext
    ) async -> MessageUpdateResult {
        let saveHTML = self.saveHTML
        let htmlContentHandler = self.htmlContentHandler
        let listRouting: ExistingListRoutingResolution
        if let anchoredListConversationObjectID =
            remoteCommittedSendMutation?.anchoredListConversationObjectID {
            listRouting = ExistingListRoutingResolution(
                existingMessageObjectID: nil,
                destinationObjectID: anchoredListConversationObjectID,
                shouldPersistIncomingListId: true
            )
        } else {
            listRouting = await resolveExistingListMessageDestination(
                for: processedMessage,
                myAliases: myAliases,
                in: context
            )
        }

        let result: MessageUpdateResult = await context.perform {
            let existingMessage: Message?
            do {
                if let existingMessageObjectID = listRouting.existingMessageObjectID {
                    existingMessage = try context.existingObject(
                        with: existingMessageObjectID
                    ) as? Message
                } else {
                    let request = Message.fetchRequest()
                    request.predicate = MessagePredicates.id(processedMessage.id)
                    request.fetchLimit = 1
                    existingMessage = try context.fetch(request).first
                }
            } catch {
                Log.error("Failed to fetch message for update", category: .coreData, error: error)
                return MessageUpdateResult(
                    didUpdate: false,
                    lookupFailed: true,
                    modifiedConversationID: nil,
                    reroutedFromConversationID: nil,
                    shouldInvalidateRenderedContent: false,
                    htmlSourceDidChange: false,
                    changedHTMLSourceSignature: nil,
                    participantDisplayNameUpdateEmails: [],
                    participantDisplayNameUpdateConversationIDs: []
                )
            }

            guard let existingMessage, !existingMessage.isDeleted else {
                return MessageUpdateResult(
                    didUpdate: false,
                    modifiedConversationID: nil,
                    reroutedFromConversationID: nil,
                    shouldInvalidateRenderedContent: false,
                    htmlSourceDidChange: false,
                    changedHTMLSourceSignature: nil,
                    participantDisplayNameUpdateEmails: [],
                    participantDisplayNameUpdateConversationIDs: []
                )
            }

            let hasAnchoredListRoute =
                remoteCommittedSendMutation?.anchoredListConversationObjectID != nil
            let routingDestination: Conversation? = listRouting.destinationObjectID.flatMap {
                guard let conversation =
                    try? context.existingObject(with: $0) as? Conversation,
                    !conversation.isDeleted,
                    !hasAnchoredListRoute || !conversation.isRetainedDrainedShell else {
                    return nil
                }
                return conversation
            }
            let canApplyAnchoredListRoute = !hasAnchoredListRoute ||
                routingDestination != nil
            let canPersistIncomingListId = listRouting.shouldPersistIncomingListId &&
                (listRouting.destinationObjectID == nil || routingDestination != nil)

            let previousWasUnread = existingMessage.isUnread
            let previousHadInboxLabel = existingMessage.labels?.contains { $0.id == "INBOX" } ?? false
            let previousSnippet = existingMessage.snippet
            let previousBodyText = existingMessage.bodyText
            let previousChatPreviewText = existingMessage.chatPreviewText
            let previousBodyStorageURI = existingMessage.bodyStorageURI
            let previousSenderEmail = existingMessage.senderEmail
            let previousSenderName = existingMessage.senderName
            let previousIsFromMe = existingMessage.isFromMe
            var senderHeaderDisplayNameUpdateEmails = Set<String>()
            var senderHeaderDisplayNameUpdateConversationIDs = Set<NSManagedObjectID>()
            let shouldPreserveLocalMailboxState = HistoryProcessor.hasPendingLocalModification(message: existingMessage)
            let canonicalHTML = processedMessage.canonicalContent?.html ?? processedMessage.htmlBody
            let previousHTMLSourceSignature = canonicalHTML == nil ? nil : htmlContentHandler.canonicalHTMLSourceSignature(
                messageId: processedMessage.id,
                bodyStorageURI: previousBodyStorageURI
            )
            let incomingHTMLSourceSignature = canonicalHTML.flatMap {
                htmlContentHandler.canonicalHTMLSourceSignature(for: $0)
            }
            let savedBodyStorageURI = canonicalHTML.flatMap {
                saveHTML($0, processedMessage.id)?.absoluteString
            }

            existingMessage.gmThreadId = processedMessage.gmThreadId
            existingMessage.subject = MessagePreviewText.preservingExisting(
                incoming: processedMessage.headers.subject,
                existing: existingMessage.subject
            )
            existingMessage.isFromMe = processedMessage.headers.isFromMe
            existingMessage.isNewsletter = processedMessage.isNewsletter
            // Assign-only-when-parseable: refetch paths that omit headers must
            // not clear a previously stored list id.
            if canApplyAnchoredListRoute,
               let anchoredListId = remoteCommittedSendMutation?.anchoredListId {
                existingMessage.listId = anchoredListId
            } else if canPersistIncomingListId,
                      let listId = ParsedListId.parse(processedMessage.headers.listId)?.id {
                existingMessage.listId = listId
            }
            existingMessage.hasAttachments = processedMessage.hasAttachments
            // Decide body preservation before the preview overwrite: a refetch
            // of the same snippet-truncated echo must not undo the preview
            // preservation the create path (or a previous pass here) applied —
            // bodyText below keeps the authored text, so the previews must
            // keep pace or the bubble reverts to Gmail's truncated preview
            // while the full body silently survives underneath.
            let shouldPreserveOutgoingLocalBody: Bool
            if let plainText = processedMessage.plainTextBody, !plainText.isEmpty {
                shouldPreserveOutgoingLocalBody = Self.shouldPreserveOutgoingLocalBodyText(
                    previousBodyText: previousBodyText,
                    incomingBodyText: plainText,
                    incomingSnippet: processedMessage.snippet,
                    incomingCleanedSnippet: processedMessage.cleanedSnippet,
                    wasFromMe: previousIsFromMe,
                    isFromMe: processedMessage.headers.isFromMe
                )
            } else {
                shouldPreserveOutgoingLocalBody = false
            }
            if MessagePreviewText.firstNonEmpty(
                processedMessage.chatPreviewText,
                processedMessage.cleanedSnippet,
                processedMessage.snippet
            ) == nil {
                existingMessage.snippet = MessagePreviewText.nonEmpty(existingMessage.snippet)
                existingMessage.cleanedSnippet = MessagePreviewText.nonEmpty(existingMessage.cleanedSnippet)
                existingMessage.chatPreviewText = MessagePreviewText.nonEmpty(existingMessage.chatPreviewText)
            } else if shouldPreserveOutgoingLocalBody {
                // Same longer+prefix rule as the create path: keep the richer
                // preserved preview, fall back to the incoming one otherwise.
                // `snippet` deliberately follows the server value (both preview
                // consumers prefer cleanedSnippet/chatPreviewText).
                existingMessage.snippet = MessagePreviewText.nonEmpty(processedMessage.snippet)
                existingMessage.cleanedSnippet = Self.richerSupersededPreview(
                    existingMessage.cleanedSnippet,
                    replacing: MessagePreviewText.nonEmpty(processedMessage.cleanedSnippet)
                )
                existingMessage.chatPreviewText = Self.richerSupersededPreview(
                    existingMessage.chatPreviewText,
                    replacing: MessagePreviewText.nonEmpty(processedMessage.chatPreviewText)
                )
            } else {
                existingMessage.snippet = MessagePreviewText.nonEmpty(processedMessage.snippet)
                existingMessage.cleanedSnippet = MessagePreviewText.nonEmpty(processedMessage.cleanedSnippet)
                existingMessage.chatPreviewText = MessagePreviewText.nonEmpty(processedMessage.chatPreviewText)
            }
            existingMessage.deliveredToAddress = processedMessage.headers.deliveredToAddress
            existingMessage.replyFromAddress = processedMessage.headers.replyFromAddress
            if let replyTo = processedMessage.headers.replyTo,
               !replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existingMessage.replyTo = replyTo
            }
            existingMessage.setValue(processedMessage.headers.messageId, forKey: "messageId")
            existingMessage.setValue(
                processedMessage.headers.references.isEmpty ? nil : processedMessage.headers.references.joined(separator: " "),
                forKey: "references"
            )

            if let from = processedMessage.headers.from {
                var normalizedSenderEmail = previousSenderEmail.map(EmailNormalizer.normalize) ?? ""
                if let email = EmailNormalizer.extractEmail(from: from) {
                    existingMessage.setValue(email, forKey: "senderEmail")
                    normalizedSenderEmail = EmailNormalizer.normalize(email)
                }
                let displayName = EmailNormalizer.extractDisplayName(from: from)
                existingMessage.setValue(displayName, forKey: "senderName")

                let previousNormalizedSenderEmail = previousSenderEmail.map(EmailNormalizer.normalize) ?? ""
                let senderHeaderChanged = displayName != previousSenderName ||
                    normalizedSenderEmail != previousNormalizedSenderEmail
                if senderHeaderChanged {
                    for email in [previousNormalizedSenderEmail, normalizedSenderEmail] where !email.isEmpty {
                        senderHeaderDisplayNameUpdateEmails.insert(email)
                    }
                    if let conversationID = existingMessage.conversation?.objectID {
                        senderHeaderDisplayNameUpdateConversationIDs.insert(conversationID)
                    }
                }
            }

            if let plainText = processedMessage.plainTextBody, !plainText.isEmpty {
                if shouldPreserveOutgoingLocalBody {
                    Log.debug(
                        "Preserving local outgoing body text for message \(processedMessage.id) over snippet-only sync body",
                        category: .sync
                    )
                } else {
                    existingMessage.bodyText = plainText
                }
            }

            let participantDisplayNameUpdate = self.updateKnownParticipantDisplayNames(
                from: processedMessage.headers,
                in: context
            )
            let displayNameUpdateEmails = Array(
                Set(participantDisplayNameUpdate.emails)
                    .union(senderHeaderDisplayNameUpdateEmails)
            )
            PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPostAfterContextSave(
                emails: displayNameUpdateEmails,
                in: context
            )
            let displayNameUpdateConversationIDs = participantDisplayNameUpdate.conversationIDs
                .union(senderHeaderDisplayNameUpdateConversationIDs)

            if let savedBodyStorageURI {
                existingMessage.bodyStorageURI = savedBodyStorageURI
            }

            let messageLabelIds = Set(processedMessage.labelIds)
            if shouldPreserveLocalMailboxState {
                Log.debug(
                    "Preserving local mailbox state for message \(processedMessage.id) while pending action exists",
                    category: .sync
                )
            } else {
                existingMessage.isUnread = processedMessage.isUnread
                existingMessage.labels = nil
                // An empty prefetched set means the label lookup failed, not that
                // the store has no labels; treating it as authoritative would
                // strip every label relationship and let the rollup recompute
                // persist a durable zero unread count.
                let availableLabelIds = labelIds.flatMap { $0.isEmpty ? nil : messageLabelIds.intersection($0) } ?? messageLabelIds
                let effectiveLabelCache = self.fetchLabelsByIds(availableLabelIds, in: context)
                for labelId in processedMessage.labelIds {
                    if let label = effectiveLabelCache[labelId] {
                        existingMessage.addToLabels(label)
                    }
                }
            }
            let currentHasInboxLabel = existingMessage.labels?.contains { $0.id == "INBOX" } ?? false

            var existingAttachmentIds = Set(existingMessage.attachmentsArray.compactMap(\.id))
            var existingContentIds = Set(
                existingMessage.attachmentsArray.compactMap { EmailDocument.normalizedContentID($0.contentId) }
            )
            var consumedOptimisticAttachmentObjectIDs = Set<NSManagedObjectID>()

            // Remove duplicate inline attachments left by earlier syncs that
            // used non-deterministic (UUID-based) IDs.
            self.deduplicateInlineAttachments(on: existingMessage, in: context)
            context.processPendingChanges()

            // Rebuild after dedup so the sets reflect current state.
            existingAttachmentIds = Set(existingMessage.attachmentsArray.compactMap(\.id))

            // Build fingerprint set for inline-data attachments to prevent
            // re-adding the same content under a new deterministic ID.
            var existingInlineFingerprints = Set<String>()
            for attachment in existingMessage.attachmentsArray {
                let fp = self.inlineAttachmentFingerprint(attachment)
                if let fp { existingInlineFingerprints.insert(fp) }
            }

            for attachmentInfo in processedMessage.attachmentInfo {
                self.refreshSynthesizedInlineStorageIfNeeded(
                    attachmentInfo,
                    on: existingMessage
                )

                if let optimisticAttachment = self.matchingOptimisticLocalAttachment(
                    for: attachmentInfo,
                    in: existingMessage.attachmentsArray,
                    excluding: consumedOptimisticAttachmentObjectIDs
                ) {
                    let previousAttachmentID = optimisticAttachment.id
                    self.migrateOptimisticAttachmentStorage(
                        optimisticAttachment,
                        to: attachmentInfo,
                        remoteMessageID: existingMessage.id
                    )
                    self.reconcileOptimisticLocalAttachment(optimisticAttachment, with: attachmentInfo)
                    consumedOptimisticAttachmentObjectIDs.insert(optimisticAttachment.objectID)

                    if let previousAttachmentID {
                        existingAttachmentIds.remove(previousAttachmentID)
                    }
                    existingAttachmentIds.insert(attachmentInfo.id)
                    if let normalizedIncomingCID = EmailDocument.normalizedContentID(attachmentInfo.contentId) {
                        existingContentIds.insert(normalizedIncomingCID)
                    }
                    continue
                }

                if existingAttachmentIds.contains(attachmentInfo.id) {
                    continue
                }

                if let normalizedIncomingCID = EmailDocument.normalizedContentID(attachmentInfo.contentId),
                   existingContentIds.contains(normalizedIncomingCID) {
                    continue
                }

                // Skip inline attachments that match an existing one by
                // filename + mimeType + size (covers old UUID-based IDs).
                let incomingFP = self.inlineAttachmentFingerprint(for: attachmentInfo)
                if let incomingFP, existingInlineFingerprints.contains(incomingFP) {
                    continue
                }

                self.createAttachment(attachmentInfo, for: existingMessage, in: context)

                existingAttachmentIds.insert(attachmentInfo.id)
                if let normalizedIncomingCID = EmailDocument.normalizedContentID(attachmentInfo.contentId) {
                    existingContentIds.insert(normalizedIncomingCID)
                }
                if let incomingFP { existingInlineFingerprints.insert(incomingFP) }
            }
            existingMessage.hasAttachments = !existingMessage.attachmentsArray.isEmpty || processedMessage.hasAttachments

            var modifiedConversationID: NSManagedObjectID?
            var reroutedFromConversationID: NSManagedObjectID?
            if let destination = routingDestination,
               destination != existingMessage.conversation {
                let source = existingMessage.conversation
                existingMessage.conversation = destination
                context.processPendingChanges()
                if let source, let reroutedSourceRollupBuffer {
                    reroutedSourceRollupBuffer.register(source.objectID)
                }
                let sourceWillBeEmpty = source.map {
                    $0.mutableSetValue(forKey: "messages").count == 0
                } ?? false
                self.applyFastConversationListUpdateForNewMessage(
                    existingMessage,
                    in: destination,
                    hasInboxLabel: currentHasInboxLabel
                )
                modifiedConversationID = destination.objectID

                if let source, sourceWillBeEmpty {
                    destination.pinned = destination.pinned || source.pinned
                    destination.muted = destination.muted || source.muted
                }
                if let source, reroutedSourceRollupBuffer == nil {
                    // The source remains durable, so repair its rollups in the
                    // same save as the relationship move. Modification tracking
                    // is still useful to observers but is not the durability
                    // boundary for these sync-owned fields.
                    ConversationRollupSnapshot.make(
                        from: source.messages ?? []
                    ).apply(to: source)
                }
                // Never delete a drained source here. PendingAction and
                // outbound-send creation can race this reroute; retain the now
                // hidden shell so those references cannot be orphaned.
                reroutedFromConversationID = source?.objectID
            } else if let conversation = existingMessage.conversation {
                self.applyFastConversationListUpdateForExistingMessage(
                    existingMessage,
                    in: conversation,
                    previousHadInboxLabel: previousHadInboxLabel,
                    previousWasUnread: previousWasUnread,
                    currentHasInboxLabel: currentHasInboxLabel,
                    currentIsUnread: existingMessage.isUnread
                )
                modifiedConversationID = conversation.objectID
            }

            let bodyStorageURIChanged = existingMessage.bodyStorageURI != previousBodyStorageURI
            let bodyTextChanged = existingMessage.bodyText != previousBodyText
            let chatPreviewTextChanged = existingMessage.chatPreviewText != previousChatPreviewText
            let snippetChanged = existingMessage.snippet != previousSnippet
            let htmlSourceSignatureChanged = savedBodyStorageURI != nil &&
                previousHTMLSourceSignature != incomingHTMLSourceSignature

            // Keep mutation-route cleanup in the same eventual context save as
            // the message update, relationship move, and source rollup repair.
            if canApplyAnchoredListRoute {
                self.handoffOptimisticAttachmentStorage(
                    remoteCommittedSendMutation,
                    attachmentInfos: processedMessage.attachmentInfo,
                    to: existingMessage,
                    in: context
                )
                self.consumeRemoteCommittedSendMutation(
                    remoteCommittedSendMutation,
                    in: context
                )
            }
            Log.debug("Updated existing message: \(processedMessage.id)", category: .sync)

            return MessageUpdateResult(
                didUpdate: true,
                modifiedConversationID: modifiedConversationID,
                reroutedFromConversationID: reroutedFromConversationID,
                shouldInvalidateRenderedContent: bodyStorageURIChanged || bodyTextChanged || chatPreviewTextChanged || snippetChanged || htmlSourceSignatureChanged,
                htmlSourceDidChange: htmlSourceSignatureChanged,
                changedHTMLSourceSignature: htmlSourceSignatureChanged ? incomingHTMLSourceSignature : nil,
                participantDisplayNameUpdateEmails: displayNameUpdateEmails,
                participantDisplayNameUpdateConversationIDs: displayNameUpdateConversationIDs
            )
        }

        if result.didUpdate {
            await scheduleInlineCIDPrefetchIfNeeded(for: processedMessage, in: context)
        }

        if let modifiedConversationID = result.modifiedConversationID {
            await ModificationTracker.shared.trackModifiedConversation(
                modifiedConversationID,
                in: modificationTransaction
            )
        }
        if let reroutedFromConversationID = result.reroutedFromConversationID {
            await ModificationTracker.shared.trackModifiedConversation(
                reroutedFromConversationID,
                in: modificationTransaction
            )
        }

        var displayNameOnlyConversationIDs = result.participantDisplayNameUpdateConversationIDs
        if let modifiedConversationID = result.modifiedConversationID {
            displayNameOnlyConversationIDs.remove(modifiedConversationID)
        }
        if let reroutedFromConversationID = result.reroutedFromConversationID {
            displayNameOnlyConversationIDs.remove(reroutedFromConversationID)
        }
        await ModificationTracker.shared.trackDisplayNameOnlyConversations(
            displayNameOnlyConversationIDs,
            in: modificationTransaction
        )

        if result.shouldInvalidateRenderedContent {
            await ProcessedTextCache.shared.invalidate(messageId: processedMessage.id)
            await HTMLContentLoader.shared.invalidateContent(messageId: processedMessage.id)
        }

        if result.htmlSourceDidChange {
            await HTMLContentLoader.postContentSourceDidChange(
                messageId: processedMessage.id,
                sourceSignature: result.changedHTMLSourceSignature
            )
        }

        return result
    }

    private struct ExistingListRoutingResolution {
        let existingMessageObjectID: NSManagedObjectID?
        let destinationObjectID: NSManagedObjectID?
        let shouldPersistIncomingListId: Bool

        static let notNeeded = ExistingListRoutingResolution(
            existingMessageObjectID: nil,
            destinationObjectID: nil,
            shouldPersistIncomingListId: true
        )
    }

    /// Opportunistically repairs one fully refetched legacy row. This is
    /// deliberately per-message: rows whose old payload no longer includes
    /// List-Id remain forward-only rather than triggering an all-mail refetch.
    private func resolveExistingListMessageDestination(
        for processedMessage: ProcessedMessage,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async -> ExistingListRoutingResolution {
        guard let incomingListId = ParsedListId.parse(processedMessage.headers.listId)?.id else {
            return .notNeeded
        }

        let routingProbe: (messageObjectID: NSManagedObjectID, needsReroute: Bool)? = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(processedMessage.id)
            request.fetchLimit = 1
            guard let message = try? context.fetch(request).first else {
                return nil
            }
            return (
                messageObjectID: message.objectID,
                needsReroute: message.conversation?.listId != incomingListId
            )
        }
        guard let routingProbe else { return .notNeeded }
        guard routingProbe.needsReroute else {
            return ExistingListRoutingResolution(
                existingMessageObjectID: routingProbe.messageObjectID,
                destinationObjectID: nil,
                shouldPersistIncomingListId: true
            )
        }

        do {
            let destinationObjectID = try await conversationRouter.resolveConversationObjectID(
                for: processedMessage,
                myAliases: myAliases,
                reuseArchivedWithoutReactivation: true,
                in: context
            )
            return ExistingListRoutingResolution(
                existingMessageObjectID: routingProbe.messageObjectID,
                destinationObjectID: destinationObjectID,
                shouldPersistIncomingListId: true
            )
        } catch {
            // Keep the old nil List-Id and participant-keyed placement so a
            // later full refetch retries instead of persisting split identity.
            Log.error(
                "Failed to reroute refetched list message \(processedMessage.id)",
                category: .coreData,
                error: error
            )
            return ExistingListRoutingResolution(
                existingMessageObjectID: routingProbe.messageObjectID,
                destinationObjectID: nil,
                shouldPersistIncomingListId: false
            )
        }
    }

    private nonisolated static func shouldPreserveOutgoingLocalBodyText(
        previousBodyText: String?,
        incomingBodyText: String,
        incomingSnippet: String?,
        incomingCleanedSnippet: String?,
        wasFromMe: Bool,
        isFromMe: Bool
    ) -> Bool {
        guard wasFromMe, isFromMe,
              let previous = normalizedBodyComparisonText(previousBodyText),
              let incoming = normalizedBodyComparisonText(incomingBodyText),
              previous.count > incoming.count,
              previous.hasPrefix(incoming) else {
            return false
        }

        let snippetCandidates = [incomingSnippet, incomingCleanedSnippet]
            .compactMap(normalizedBodyComparisonText)
        guard !snippetCandidates.isEmpty else {
            return false
        }

        return snippetCandidates.contains(incoming)
    }

    nonisolated static func normalizedBodyComparisonText(_ text: String?) -> String? {
        guard let text else { return nil }

        let normalized = HTMLEntityDecoder.decode(
            RawEmailSourceSanitizer.extractDisplayText(from: text)
        )
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        return normalized.isEmpty ? nil : normalized
    }

    nonisolated func matchingOptimisticLocalAttachment(
        for attachmentInfo: AttachmentInfo,
        in attachments: [Attachment],
        excluding excludedObjectIDs: Set<NSManagedObjectID>
    ) -> Attachment? {
        optimisticLocalAttachmentCandidates(
            for: attachmentInfo,
            in: attachments,
            excluding: excludedObjectIDs
        ).first
    }

    private nonisolated func optimisticLocalAttachmentCandidates(
        for attachmentInfo: AttachmentInfo,
        in attachments: [Attachment],
        excluding excludedObjectIDs: Set<NSManagedObjectID>
    ) -> [Attachment] {
        let localCandidates = attachments.filter {
            $0.isLocalAttachment &&
                !($0.id?.hasPrefix("local_inline_") ?? false) &&
                !excludedObjectIDs.contains($0.objectID)
        }

        guard !localCandidates.isEmpty else { return [] }

        if let normalizedIncomingCID = EmailDocument.normalizedContentID(attachmentInfo.contentId) {
            let cidMatches = localCandidates.filter {
                EmailDocument.normalizedContentID($0.contentId) == normalizedIncomingCID
            }
            if !cidMatches.isEmpty {
                return cidMatches
            }
        }

        let normalizedIncomingFilename = normalizedAttachmentFilename(attachmentInfo.filename)
        let incomingSize = Int64(attachmentInfo.size)

        return localCandidates.filter {
            EmailDocument.normalizedContentID($0.contentId) == nil &&
            normalizedAttachmentFilename($0.filename) == normalizedIncomingFilename &&
            $0.mimeType == attachmentInfo.mimeType &&
            $0.byteSize == incomingSize
        }
    }

    /// Copies a superseded optimistic send's known-good local files into the
    /// collision-safe storage identity of its exact Gmail echo. The old paths
    /// are then detached from the object being deleted, so CacheCoordinator
    /// cannot remove a URL that an already-open QuickLook controller still uses.
    nonisolated func handoffOptimisticAttachmentStorage(
        _ resolution: RemoteCommittedSendMutationResolution?,
        attachmentInfos: [AttachmentInfo],
        to remoteMessage: Message,
        in context: NSManagedObjectContext
    ) {
        guard let resolution,
              resolution.shouldConsumeAfterPersistence,
              !resolution.supersededOptimisticMessages.isEmpty,
              !attachmentInfos.isEmpty else {
            return
        }

        let optimisticAttachments = resolution.supersededOptimisticMessages.keys
            .compactMap { objectID -> Message? in
                guard let message = try? context.existingObject(with: objectID) as? Message,
                      !message.isDeleted else {
                    return nil
                }
                return message
            }
            .flatMap(\.attachmentsArray)
        guard !optimisticAttachments.isEmpty else { return }

        AttachmentPaths.setupDirectories()
        let handoffMatches = attachmentInfos.map { info -> (
            info: AttachmentInfo,
            remoteAttachment: Attachment?,
            optimisticCandidates: [Attachment]
        ) in
            let remoteAttachment = remoteMessage.attachmentsArray.first(where: {
                $0.id == info.id && !$0.isDeleted
            })
            let optimisticCandidates = remoteAttachment.map { _ in
                optimisticLocalAttachmentCandidates(
                    for: info,
                    in: optimisticAttachments,
                    excluding: []
                )
            } ?? []
            return (info, remoteAttachment, optimisticCandidates)
        }

        // A metadata fingerprint is only safe across different message graphs
        // when it identifies one attachment on both sides. Leave every
        // ambiguous remote attachment queued for its normal Gmail download.
        var remoteMatchCountsByOptimisticObjectID: [NSManagedObjectID: Int] = [:]
        for match in handoffMatches {
            for candidate in match.optimisticCandidates {
                remoteMatchCountsByOptimisticObjectID[candidate.objectID, default: 0] += 1
            }
        }

        for match in handoffMatches {
            guard let remoteAttachment = match.remoteAttachment,
                  match.optimisticCandidates.count == 1,
                  let optimisticAttachment = match.optimisticCandidates.first,
                  remoteMatchCountsByOptimisticObjectID[optimisticAttachment.objectID] == 1 else {
                continue
            }

            handoffOptimisticAttachmentStorage(
                optimisticAttachment,
                to: remoteAttachment,
                info: match.info,
                remoteMessageID: remoteMessage.id
            )
        }
    }

    private nonisolated func handoffOptimisticAttachmentStorage(
        _ optimisticAttachment: Attachment,
        to remoteAttachment: Attachment,
        info: AttachmentInfo,
        remoteMessageID: String
    ) {
        guard let remoteAttachmentID = remoteAttachment.id else { return }

        let filenameExtension = (info.filename as NSString).pathExtension.lowercased()
        let originalExtension = filenameExtension.isEmpty
            ? AttachmentPaths.fileExtension(for: info.mimeType)
            : filenameExtension
        let remoteOriginalPath = AttachmentPaths.originalPath(
            messageId: remoteMessageID,
            attachmentId: remoteAttachmentID,
            ext: originalExtension
        )
        let remotePreviewPath = AttachmentPaths.previewPath(
            messageId: remoteMessageID,
            attachmentId: remoteAttachmentID
        )

        let hasRemoteOriginal: Bool
        if readableFileExists(
            remoteAttachment.localURL,
            messageId: remoteMessageID,
            attachmentId: remoteAttachmentID
        ) {
            hasRemoteOriginal = true
            remoteAttachment.state = .downloaded
            remoteAttachment.lastDownloadFailedAt = nil
        } else if copyAttachmentFile(
            from: optimisticAttachment.localURL,
            to: remoteOriginalPath
        ) {
            hasRemoteOriginal = true
            remoteAttachment.localURL = remoteOriginalPath
            remoteAttachment.state = .downloaded
            remoteAttachment.lastDownloadFailedAt = nil
        } else {
            hasRemoteOriginal = false
        }

        let hasRemotePreview: Bool
        if readableFileExists(
            remoteAttachment.previewURL,
            messageId: remoteMessageID,
            attachmentId: remoteAttachmentID
        ) {
            hasRemotePreview = true
        } else if copyAttachmentFile(
            from: optimisticAttachment.previewURL,
            to: remotePreviewPath
        ) {
            hasRemotePreview = true
            remoteAttachment.previewURL = remotePreviewPath
        } else {
            hasRemotePreview = false
        }

        if remoteAttachment.width == 0 {
            remoteAttachment.width = optimisticAttachment.width
        }
        if remoteAttachment.height == 0 {
            remoteAttachment.height = optimisticAttachment.height
        }
        if remoteAttachment.pageCount == 0 {
            remoteAttachment.pageCount = optimisticAttachment.pageCount
        }

        // Keep the old files alive as unreferenced compatibility copies. A
        // QLPreviewItem snapshots its URL when presented, so deleting that path
        // during convergence would invalidate the active preview. Periodic
        // orphan cleanup may reclaim it after this atomic replacement.
        if hasRemoteOriginal, fileExists(at: optimisticAttachment.localURL) {
            optimisticAttachment.localURL = nil
        }
        if hasRemotePreview, fileExists(at: optimisticAttachment.previewURL) {
            optimisticAttachment.previewURL = nil
        }
    }

    private nonisolated func readableFileExists(
        _ path: String?,
        messageId: String,
        attachmentId: String
    ) -> Bool {
        AttachmentPaths.isReadableStoragePath(
            path,
            messageId: messageId,
            attachmentId: attachmentId
        ) && fileExists(at: path)
    }

    private nonisolated func copyAttachmentFile(
        from sourcePath: String?,
        to destinationPath: String
    ) -> Bool {
        guard let sourcePath,
              let sourceURL = AttachmentPaths.fullURL(for: sourcePath),
              let destinationURL = AttachmentPaths.fullURL(for: destinationPath) else {
            return false
        }
        if sourcePath == destinationPath {
            return fileExists(at: sourcePath)
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return false
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            return true
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            Log.error(
                "Failed to hand off optimistic attachment storage",
                category: .attachment,
                error: error
            )
            return false
        }
    }

    private nonisolated func fileExists(at path: String?) -> Bool {
        guard let url = AttachmentPaths.fullURL(for: path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private nonisolated func migrateOptimisticAttachmentStorage(
        _ attachment: Attachment,
        to attachmentInfo: AttachmentInfo,
        remoteMessageID: String
    ) {
        AttachmentPaths.setupDirectories()

        let filenameExtension = (attachmentInfo.filename as NSString).pathExtension.lowercased()
        let originalExtension = filenameExtension.isEmpty
            ? AttachmentPaths.fileExtension(for: attachmentInfo.mimeType)
            : filenameExtension
        let remoteOriginalPath = AttachmentPaths.originalPath(
            messageId: remoteMessageID,
            attachmentId: attachmentInfo.id,
            ext: originalExtension
        )
        let remotePreviewPath = AttachmentPaths.previewPath(
            messageId: remoteMessageID,
            attachmentId: attachmentInfo.id
        )

        if copyAttachmentFile(from: attachment.localURL, to: remoteOriginalPath) {
            attachment.localURL = remoteOriginalPath
        }
        if copyAttachmentFile(from: attachment.previewURL, to: remotePreviewPath) {
            attachment.previewURL = remotePreviewPath
        }
    }

    nonisolated func reconcileOptimisticLocalAttachment(_ attachment: Attachment, with attachmentInfo: AttachmentInfo) {
        attachment.id = attachmentInfo.id
        attachment.filename = attachmentInfo.filename
        attachment.mimeType = attachmentInfo.mimeType
        attachment.contentId = attachmentInfo.contentId

        if attachmentInfo.size > 0 {
            attachment.byteSize = Int64(attachmentInfo.size)
        }
    }

    nonisolated func normalizedAttachmentFilename(_ filename: String) -> String {
        filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated func refreshSynthesizedInlineStorageIfNeeded(
        _ info: AttachmentInfo,
        on message: Message
    ) {
        guard info.id.hasPrefix("local_inline_"),
              let inlineData = info.inlineData else {
            return
        }

        let normalizedIncomingContentID = EmailDocument.normalizedContentID(info.contentId)
        let incomingFingerprint = inlineAttachmentFingerprint(for: info)
        guard let existing = message.attachmentsArray.first(where: { attachment in
            if attachment.id == info.id {
                return true
            }
            if let normalizedIncomingContentID,
               EmailDocument.normalizedContentID(attachment.contentId) == normalizedIncomingContentID {
                return true
            }
            return incomingFingerprint != nil &&
                inlineAttachmentFingerprint(attachment) == incomingFingerprint
        }), synthesizedInlineStorageNeedsRefresh(existing, messageId: message.id) else {
            return
        }

        _ = persistInlineAttachmentData(
            inlineData,
            info: info,
            attachment: existing,
            messageId: message.id
        )
    }

    nonisolated func synthesizedInlineStorageNeedsRefresh(
        _ attachment: Attachment,
        messageId: String
    ) -> Bool {
        guard let attachmentId = attachment.id,
              AttachmentPaths.isReadableStoragePath(
                  attachment.localURL,
                  messageId: messageId,
                  attachmentId: attachmentId
              ),
              let localFileURL = AttachmentPaths.fullURL(for: attachment.localURL),
              FileManager.default.fileExists(atPath: localFileURL.path) else {
            return true
        }

        guard let previewURL = attachment.previewURL else { return false }
        guard AttachmentPaths.isReadableStoragePath(
                  previewURL,
                  messageId: messageId,
                  attachmentId: attachmentId
              ),
              let previewFileURL = AttachmentPaths.fullURL(for: previewURL),
              FileManager.default.fileExists(atPath: previewFileURL.path) else {
            return true
        }
        return false
    }

    // MARK: - Inline attachment deduplication

    /// Fingerprint for an existing Core Data attachment (filename|mimeType).
    nonisolated func inlineAttachmentFingerprint(_ attachment: Attachment) -> String? {
        guard let id = attachment.id, id.hasPrefix("local_inline_") else { return nil }
        let filename = normalizedAttachmentFilename(attachment.filename)
        let mimeType = attachment.mimeType
        return "\(filename)|\(mimeType)"
    }

    /// Fingerprint for an incoming AttachmentInfo.
    nonisolated func inlineAttachmentFingerprint(for info: AttachmentInfo) -> String? {
        guard info.id.hasPrefix("local_inline_") else { return nil }
        let filename = normalizedAttachmentFilename(info.filename)
        return "\(filename)|\(info.mimeType)"
    }

    /// Removes duplicate inline attachments, keeping only the first per fingerprint.
    nonisolated func deduplicateInlineAttachments(on message: Message, in context: NSManagedObjectContext) {
        autoreleasepool {
            var bestAttachmentByContentID: [String: Attachment] = [:]

            for attachment in message.attachmentsArray {
                guard let contentID = EmailDocument.normalizedContentID(attachment.contentId) else { continue }

                if let existing = bestAttachmentByContentID[contentID] {
                    if shouldPreferInlineAttachment(attachment, over: existing) {
                        context.delete(existing)
                        bestAttachmentByContentID[contentID] = attachment
                    } else {
                        context.delete(attachment)
                    }
                } else {
                    bestAttachmentByContentID[contentID] = attachment
                }
            }

            var seen = Set<String>()
            for attachment in message.attachmentsArray {
                if attachment.isDeleted {
                    continue
                }
                guard let fp = inlineAttachmentFingerprint(attachment) else { continue }
                if seen.contains(fp) {
                    context.delete(attachment)
                } else {
                    seen.insert(fp)
                }
            }
        }
    }

    nonisolated func shouldPreferInlineAttachment(_ lhs: Attachment, over rhs: Attachment) -> Bool {
        inlineAttachmentRetentionScore(lhs) > inlineAttachmentRetentionScore(rhs)
    }

    nonisolated func inlineAttachmentRetentionScore(_ attachment: Attachment) -> Int {
        var score = 0

        if !(attachment.id?.hasPrefix("local_inline_") ?? false) {
            score += 8
        }
        if attachment.localURL != nil {
            score += 16
        }
        if attachment.previewURL != nil {
            score += 8
        }
        if attachment.isReady {
            score += 4
        }
        if attachment.byteSize > 0 {
            score += 2
        }

        return score
    }
}
