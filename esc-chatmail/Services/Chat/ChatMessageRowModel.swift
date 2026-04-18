import Foundation
import CoreData

private enum ChatMessageAttachmentDeduplicationKey: Hashable {
    case contentId(String)
    case file(filename: String, mimeType: String, byteSize: Int64)
    case objectID(NSManagedObjectID)
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
    let forwardedDisplaySubject: String?
    let outgoingForwardedDisplayContent: ForwardedMessageDisplayContent?

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
            personAvatarURL: senderInfoAvatarURL
        )
    }

    func makeContentRequest() -> MessageBubbleContentRequest {
        MessageBubbleContentRequest(
            messageID: id,
            bodyText: bodyText,
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
        let allAttachments = deduplicatedAttachments(in: attachments.filter { attachment in
            guard !attachment.isLikelySignatureImage else { return false }

            guard let contentId = MessageBubbleHTMLAnalysisBuilder.normalizedContentID(from: attachment.contentId) else {
                return true
            }

            return !htmlAnalysis.nonDisplayableInlineContentIDs.contains(contentId)
        })

        guard hidingInlineReferencedInHTML else {
            return allAttachments
        }

        guard !isFromMe else {
            return allAttachments
        }

        let cidFilteredAttachments: [ChatMessageAttachmentModel]
        if htmlAnalysis.referencedInlineContentIDs.isEmpty {
            cidFilteredAttachments = allAttachments
        } else {
            cidFilteredAttachments = allAttachments.filter { attachment in
                guard let contentId = MessageBubbleHTMLAnalysisBuilder.normalizedContentID(from: attachment.contentId) else {
                    return true
                }
                return !htmlAnalysis.referencedInlineContentIDs.contains(contentId)
            }
        }

        let shouldHideCalendarInviteAttachments =
            hidingCalendarInviteAttachments ?? htmlAnalysis.supportsCalendarInvitePreviewCard

        guard shouldHideCalendarInviteAttachments else {
            return cidFilteredAttachments
        }

        return cidFilteredAttachments.filter { !$0.isCalendarInviteAttachment }
    }

    private func deduplicatedAttachments(
        in attachments: [ChatMessageAttachmentModel]
    ) -> [ChatMessageAttachmentModel] {
        var bestByKey: [ChatMessageAttachmentDeduplicationKey: (index: Int, attachment: ChatMessageAttachmentModel)] = [:]
        var deduplicated: [ChatMessageAttachmentModel] = []

        for attachment in attachments {
            let key = attachmentDeduplicationKey(for: attachment)

            if let existing = bestByKey[key] {
                if shouldPreferDeduplicatedAttachment(attachment, over: existing.attachment) {
                    deduplicated[existing.index] = attachment
                    bestByKey[key] = (existing.index, attachment)
                }
                continue
            }

            bestByKey[key] = (deduplicated.count, attachment)
            deduplicated.append(attachment)
        }

        return deduplicated
    }

    private func attachmentDeduplicationKey(
        for attachment: ChatMessageAttachmentModel
    ) -> ChatMessageAttachmentDeduplicationKey {
        if let normalizedContentId = MessageBubbleHTMLAnalysisBuilder.normalizedContentID(from: attachment.contentId) {
            return .contentId(normalizedContentId)
        }

        let normalizedFilename = attachment.filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedMimeType = attachment.mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if !normalizedFilename.isEmpty || !normalizedMimeType.isEmpty || attachment.byteSize > 0 {
            return .file(
                filename: normalizedFilename,
                mimeType: normalizedMimeType,
                byteSize: attachment.byteSize
            )
        }

        return .objectID(attachment.objectID)
    }

    private func shouldPreferDeduplicatedAttachment(
        _ lhs: ChatMessageAttachmentModel,
        over rhs: ChatMessageAttachmentModel
    ) -> Bool {
        deduplicatedAttachmentRetentionScore(lhs) > deduplicatedAttachmentRetentionScore(rhs)
    }

    private func deduplicatedAttachmentRetentionScore(
        _ attachment: ChatMessageAttachmentModel
    ) -> Int {
        var score = 0

        if attachment.isReady {
            score += 4
        }
        if attachment.localURL != nil {
            score += 2
        }
        if attachment.byteSize > 0 {
            score += 1
        }
        if attachment.pageCount > 0 || attachment.width > 0 || attachment.height > 0 {
            score += 1
        }

        return score
    }
}

enum ChatMessageRowModelMapper {
    @MainActor
    static func map(_ message: Message) -> ChatMessageRowModel {
        let senderParticipant = message.participants?
            .first(where: { $0.participantKind == .from })
        let senderPerson = senderParticipant?.person
        let headerSenderEmail = normalizedSenderEmail(message.senderEmail)
        let effectiveSenderEmail = resolvedSenderEmail(for: message, senderPerson: senderPerson)

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
            bodyText: message.bodyTextValue,
            bodyStorageURI: message.bodyStorageURI,
            senderName: message.senderName,
            senderEmail: headerSenderEmail,
            effectiveSenderEmail: effectiveSenderEmail,
            senderGroupingKeyInput: effectiveSenderEmail,
            senderInfoEmail: senderPerson?.email,
            senderInfoDisplayName: senderPerson?.displayName,
            senderInfoAvatarURL: senderPerson?.avatarURL,
            isNewsletter: message.isNewsletter,
            hasHTMLSource: message.hasHTMLSource,
            isForwardedEmail: message.isForwardedEmail,
            isLikelyCalendarInvite: message.isLikelyCalendarInvite,
            htmlDisplayCleanupMode: message.htmlDisplayCleanupMode,
            hasAttachments: message.hasAttachments,
            attachments: message.attachmentsArray.map(map),
            isSendingLocalAttachments: message.isSendingLocalAttachments,
            hasFailedLocalAttachmentUploads: message.hasFailedLocalAttachmentUploads,
            forwardedDisplaySubject: message.forwardedDisplaySubject,
            outgoingForwardedDisplayContent: message.outgoingForwardedDisplayContent
        )
    }

    @MainActor
    static func map(_ messages: [Message]) -> [ChatMessageRowModel] {
        messages.map(map)
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
