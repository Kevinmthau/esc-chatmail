import Foundation
import CoreData
import CryptoKit

struct MessageBubbleLoadSignatureComponents: Equatable {
    let bodyStorageURI: String?
    private let bodyTextFingerprint: String
    private let chatPreviewTextFingerprint: String
    private let cleanedSnippetFingerprint: String
    private let snippetFingerprint: String
    private let hasHTMLSource: Bool
    private let senderEmailFingerprint: String
    private let senderDisplayNameFingerprint: String
    private let senderHeaderDisplayNameFingerprint: String
    private let senderAvatarURLFingerprint: String

    init(
        bodyStorageURI: String?,
        bodyText: String?,
        chatPreviewText: String? = nil,
        cleanedSnippet: String?,
        snippet: String?,
        hasHTMLSource: Bool,
        senderEmail: String? = nil,
        senderDisplayName: String? = nil,
        senderHeaderDisplayName: String? = nil,
        senderAvatarURL: String? = nil
    ) {
        self.bodyStorageURI = bodyStorageURI
        self.bodyTextFingerprint = Self.contentFingerprint(for: bodyText)
        self.chatPreviewTextFingerprint = Self.contentFingerprint(for: chatPreviewText)
        self.cleanedSnippetFingerprint = Self.contentFingerprint(for: cleanedSnippet)
        self.snippetFingerprint = Self.contentFingerprint(for: snippet)
        self.hasHTMLSource = hasHTMLSource
        self.senderEmailFingerprint = Self.contentFingerprint(for: senderEmail)
        self.senderDisplayNameFingerprint = Self.contentFingerprint(for: senderDisplayName)
        self.senderHeaderDisplayNameFingerprint = Self.contentFingerprint(for: senderHeaderDisplayName)
        self.senderAvatarURLFingerprint = Self.contentFingerprint(for: senderAvatarURL)
    }

    func signature(
        htmlSourceSignature: String,
        contactRefreshToken: Int
    ) -> String {
        [
            bodyStorageURI ?? "",
            bodyTextFingerprint,
            chatPreviewTextFingerprint,
            cleanedSnippetFingerprint,
            snippetFingerprint,
            String(hasHTMLSource),
            "source:\(htmlSourceSignature)",
            "contacts:\(contactRefreshToken)",
            "senderEmail:\(senderEmailFingerprint)",
            "senderName:\(senderDisplayNameFingerprint)",
            "senderHeaderName:\(senderHeaderDisplayNameFingerprint)",
            "senderAvatar:\(senderAvatarURLFingerprint)"
        ].joined(separator: "|")
    }

    static func signature(
        bodyStorageURI: String?,
        bodyText: String?,
        chatPreviewText: String? = nil,
        cleanedSnippet: String? = nil,
        snippet: String?,
        hasHTMLSource: Bool,
        htmlSourceSignature: String,
        contactRefreshToken: Int,
        senderEmail: String? = nil,
        senderDisplayName: String? = nil,
        senderHeaderDisplayName: String? = nil,
        senderAvatarURL: String? = nil
    ) -> String {
        Self(
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            chatPreviewText: chatPreviewText,
            cleanedSnippet: cleanedSnippet,
            snippet: snippet,
            hasHTMLSource: hasHTMLSource,
            senderEmail: senderEmail,
            senderDisplayName: senderDisplayName,
            senderHeaderDisplayName: senderHeaderDisplayName,
            senderAvatarURL: senderAvatarURL
        ).signature(
            htmlSourceSignature: htmlSourceSignature,
            contactRefreshToken: contactRefreshToken
        )
    }

    private static func contentFingerprint(for text: String?) -> String {
        guard let text else { return "nil" }
        return SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ChatMessageAttachmentModel: Equatable {
    let objectID: NSManagedObjectID
    let attachmentID: String?
    let contentId: String?
    let filename: String
    let mimeType: String
    let stateRaw: String
    let localURL: String?
    let previewURL: String?
    let byteSize: Int64
    let pageCount: Int16
    let width: Int16
    let height: Int16

    var state: Attachment.State {
        Attachment.State(rawValue: stateRaw) ?? .queued
    }

    var isReady: Bool {
        state == .downloaded || state == .uploaded
    }

    var isImage: Bool {
        mimeType.starts(with: "image/")
    }

    var isVideo: Bool {
        mimeType.starts(with: "video/")
    }

    var isPDF: Bool {
        mimeType == "application/pdf"
    }

    var isLocalAttachment: Bool {
        attachmentID?.starts(with: "local_") == true
    }

    var needsRedownload: Bool {
        guard isReady else { return false }
        guard let localPath = localURL else { return true }
        guard let fullURL = AttachmentPaths.fullURL(for: localPath) else { return true }
        return !FileManager.default.fileExists(atPath: fullURL.path)
    }

    var isCalendarInviteAttachment: Bool {
        let normalizedMimeType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedFilename = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedMimeType.hasPrefix("text/calendar") ||
            normalizedMimeType == "application/ics" ||
            normalizedMimeType == "application/ical" ||
            normalizedMimeType == "application/x-ical" ||
            normalizedFilename.hasSuffix(".ics")
    }

    var isLikelySignatureImage: Bool {
        guard mimeType.hasPrefix("image/") else { return false }

        if byteSize > 0 && byteSize < AttachmentConfig.signatureImageMaxBytes {
            return true
        }

        if width > 0 && height > 0 &&
            width <= AttachmentConfig.signatureImageMaxDimension &&
            height <= AttachmentConfig.signatureImageMaxDimension {
            return true
        }

        return false
    }

    var bubbleSnapshot: MessageBubbleAttachmentSnapshot {
        MessageBubbleAttachmentSnapshot(
            contentId: contentId,
            filename: filename,
            mimeType: mimeType,
            stateRaw: stateRaw,
            localURL: localURL,
            byteSize: byteSize,
            pageCount: pageCount,
            width: width,
            height: height
        )
    }
}

struct ChatMessageRowModel: Equatable {
    let id: String
    let messageObjectID: NSManagedObjectID
    let conversationObjectID: NSManagedObjectID?
    let isFromMe: Bool
    let isUnread: Bool
    let internalDate: Date
    let subject: String?
    let snippet: String?
    let cleanedSnippet: String?
    let chatPreviewText: String?
    let bodyText: String?
    let bodyStorageURI: String?
    let senderName: String?
    let senderEmail: String?
    let effectiveSenderEmail: String?
    let senderGroupingKeyInput: String?
    let senderInfoEmail: String?
    let senderInfoDisplayName: String?
    let senderInfoAvatarURL: String?
    let isNewsletter: Bool
    let hasHTMLSource: Bool
    let isForwardedEmail: Bool
    let isLikelyCalendarInvite: Bool
    let htmlDisplayCleanupMode: HTMLContentCleanupMode
    let hasAttachments: Bool
    let attachments: [ChatMessageAttachmentModel]
    let isSendingLocalAttachments: Bool
    let hasFailedLocalAttachmentUploads: Bool
    let outboundSendDeliveryState: OutboundSendDeliveryState
    let forwardedDisplaySubject: String?
    let outgoingForwardedDisplayContent: ForwardedMessageDisplayContent?
    /// Precomputed so MessageBubble body recomputation does not hash message text.
    let loadSignatureComponents: MessageBubbleLoadSignatureComponents

    var hasOriginalEmailContent: Bool {
        MessageOriginalEmailOpenPolicy.hasOriginalEmailContent(
            hasHTMLSource: hasHTMLSource,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText
        )
    }

    var objectID: NSManagedObjectID {
        messageObjectID
    }

    var fallbackPreviewText: String? {
        cleanedSnippet ?? snippet
    }

    func makeSenderRequest() -> MessageBubbleSenderRequest? {
        guard !isFromMe, let senderInfoEmail else {
            return nil
        }

        return MessageBubbleSenderRequest(
            email: senderInfoEmail,
            personDisplayName: senderInfoDisplayName,
            personAvatarURL: senderInfoAvatarURL,
            headerDisplayName: senderName
        )
    }

    func makeContentRequest() -> MessageBubbleContentRequest {
        MessageBubbleContentRequest(
            messageID: id,
            bodyText: bodyText,
            chatPreviewText: chatPreviewText,
            bodyStorageURI: bodyStorageURI,
            cleanedSnippet: cleanedSnippet,
            snippet: snippet,
            subject: subject,
            senderName: senderName,
            hasHTMLSource: hasHTMLSource,
            hasAttachments: hasAttachments,
            isFromMe: isFromMe,
            isForwardedEmail: isForwardedEmail,
            isLikelyCalendarInvite: isLikelyCalendarInvite,
            effectiveSenderEmail: effectiveSenderEmail,
            attachmentSnapshots: attachments.map(\.bubbleSnapshot)
        )
    }

    func displayableAttachments(
        using htmlAnalysis: MessageBubbleHTMLAnalysis,
        hidingInlineReferencedInHTML: Bool,
        hidingCalendarInviteAttachments: Bool? = nil
    ) -> [ChatMessageAttachmentModel] {
        AttachmentDisplayFilter.displayableAttachments(
            in: attachments,
            using: htmlAnalysis,
            isFromMe: isFromMe,
            hidingInlineReferencedInHTML: hidingInlineReferencedInHTML,
            hidingCalendarInviteAttachments: hidingCalendarInviteAttachments
        )
    }
}

enum ChatMessageRowModelMapper {
    @MainActor
    static func map(_ message: Message) -> ChatMessageRowModel {
        map(
            message,
            outboundSendDeliveryState: OutboundSendDeliveryState.resolve(for: message)
        )
    }

    @MainActor
    private static func map(
        _ message: Message,
        outboundSendDeliveryState: OutboundSendDeliveryState
    ) -> ChatMessageRowModel {
        let senderParticipant = message.participants?
            .first(where: { $0.participantKind == .from })
        let senderPerson = senderParticipant?.person
        let headerSenderEmail = normalizedSenderEmail(message.senderEmail)
        let effectiveSenderEmail = resolvedSenderEmail(for: message, senderPerson: senderPerson)
        let effectiveSenderPerson: Person? = senderPerson.flatMap { person in
            guard let effectiveSenderEmail,
                  EmailNormalizer.normalize(person.email) == EmailNormalizer.normalize(effectiveSenderEmail) else {
                return nil
            }
            return person
        }

        return ChatMessageRowModel(
            id: message.id,
            messageObjectID: message.objectID,
            conversationObjectID: message.conversation?.objectID,
            isFromMe: message.isFromMe,
            isUnread: message.isUnread,
            internalDate: message.internalDate,
            subject: message.subject,
            snippet: message.snippet,
            cleanedSnippet: message.cleanedSnippet,
            chatPreviewText: message.chatPreviewTextValue,
            bodyText: message.bodyTextValue,
            bodyStorageURI: message.bodyStorageURI,
            senderName: message.senderName,
            senderEmail: headerSenderEmail,
            effectiveSenderEmail: effectiveSenderEmail,
            senderGroupingKeyInput: effectiveSenderEmail,
            senderInfoEmail: effectiveSenderEmail,
            senderInfoDisplayName: effectiveSenderPerson?.displayName,
            senderInfoAvatarURL: effectiveSenderPerson?.avatarURL,
            isNewsletter: message.isNewsletter,
            hasHTMLSource: message.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isLikelyCalendarInvite: message.isLikelyCalendarInvite,
            htmlDisplayCleanupMode: message.htmlDisplayCleanupMode,
            hasAttachments: message.hasAttachments,
            attachments: message.attachmentsArray.map(map),
            isSendingLocalAttachments: message.isSendingLocalAttachments,
            hasFailedLocalAttachmentUploads: message.hasFailedLocalAttachmentUploads,
            outboundSendDeliveryState: outboundSendDeliveryState,
            forwardedDisplaySubject: message.forwardedDisplaySubject,
            outgoingForwardedDisplayContent: message.outgoingForwardedDisplayContent,
            loadSignatureComponents: MessageBubbleLoadSignatureComponents(
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyTextValue,
                chatPreviewText: message.chatPreviewTextValue,
                cleanedSnippet: message.cleanedSnippet,
                snippet: message.snippet,
                hasHTMLSource: message.hasHTMLSource,
                senderEmail: effectiveSenderEmail,
                senderDisplayName: effectiveSenderPerson?.displayName,
                senderHeaderDisplayName: message.senderName,
                senderAvatarURL: effectiveSenderPerson?.avatarURL
            )
        )
    }

    @MainActor
    static func map(_ messages: [Message]) -> [ChatMessageRowModel] {
        map(messages) { context, optimisticMessageIDs in
            let request = OutboundSendMutationRecord.fetchRequest()
            request.predicate = NSPredicate(
                format: "id IN %@",
                Array(optimisticMessageIDs)
            )
            request.fetchBatchSize = optimisticMessageIDs.count
            request.includesPendingChanges = true
            return try context.fetch(request)
        }
    }

    /// Testable batch seam: production passes one fetch per managed-object
    /// context, regardless of how many optimistic rows are in the window.
    @MainActor
    static func map(
        _ messages: [Message],
        fetchOutboundSendMutationRecords: (
            _ context: NSManagedObjectContext,
            _ optimisticMessageIDs: Set<String>
        ) throws -> [OutboundSendMutationRecord]
    ) -> [ChatMessageRowModel] {
        struct CandidateGroup {
            let context: NSManagedObjectContext
            var messages: [Message]
            var optimisticMessageIDs: Set<String>
        }

        var groups: [ObjectIdentifier: CandidateGroup] = [:]
        for message in messages {
            guard let optimisticMessageID = OutboundSendDeliveryState
                .localOptimisticMessageID(for: message),
                  let context = message.managedObjectContext else {
                continue
            }

            let contextID = ObjectIdentifier(context)
            if var group = groups[contextID] {
                group.messages.append(message)
                group.optimisticMessageIDs.insert(optimisticMessageID)
                groups[contextID] = group
            } else {
                groups[contextID] = CandidateGroup(
                    context: context,
                    messages: [message],
                    optimisticMessageIDs: [optimisticMessageID]
                )
            }
        }

        var statesByMessageObjectID: [
            NSManagedObjectID: OutboundSendDeliveryState
        ] = [:]
        for group in groups.values {
            let records: [OutboundSendMutationRecord]
            do {
                records = try fetchOutboundSendMutationRecords(
                    group.context,
                    group.optimisticMessageIDs
                )
            } catch {
                Log.error(
                    "Failed to batch-fetch outbound send delivery states",
                    category: .coreData,
                    error: error
                )
                continue
            }

            var recordsByID: [String: OutboundSendMutationRecord] = [:]
            for record in records where recordsByID[record.id] == nil {
                recordsByID[record.id] = record
            }
            for message in group.messages {
                guard let record = recordsByID[message.id] else { continue }
                statesByMessageObjectID[message.objectID] =
                    OutboundSendRemoteState.deliveryState(
                        messageID: record.remoteCommittedMessageId,
                        threadID: record.remoteCommittedThreadId
                    )
            }
        }

        return messages.map { message in
            map(
                message,
                outboundSendDeliveryState:
                    statesByMessageObjectID[message.objectID] ?? .none
            )
        }
    }

    private static func map(_ attachment: Attachment) -> ChatMessageAttachmentModel {
        ChatMessageAttachmentModel(
            objectID: attachment.objectID,
            attachmentID: attachment.id,
            contentId: attachment.contentId,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            stateRaw: attachment.stateRaw,
            localURL: attachment.localURL,
            previewURL: attachment.previewURL,
            byteSize: attachment.byteSize,
            pageCount: attachment.pageCount,
            width: attachment.width,
            height: attachment.height
        )
    }

    private static func resolvedSenderEmail(
        for message: Message,
        senderPerson: Person?
    ) -> String? {
        if let senderEmail = normalizedSenderEmail(message.senderEmail) {
            return senderEmail
        }

        return senderPerson?.email
    }

    private static func normalizedSenderEmail(_ senderEmail: String?) -> String? {
        guard let senderEmail = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !senderEmail.isEmpty else {
            return nil
        }

        return senderEmail
    }
}

enum ChatMessageRowGrouping {
    static func isLastFromSender(
        current: ChatMessageRowModel,
        next: ChatMessageRowModel?,
        senderRunKey: (ChatMessageRowModel?) -> String?
    ) -> Bool {
        next == nil ||
            senderRunKey(next) != senderRunKey(current) ||
            next?.isFromMe != current.isFromMe
    }
}
