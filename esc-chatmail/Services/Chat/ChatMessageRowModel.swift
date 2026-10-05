import Foundation
import CoreData

struct MessageBubbleLoadSignatureComponents: Equatable {
    let bodyStorageURI: String?
    private let bodyTextFingerprint: Int?
    private let chatPreviewTextFingerprint: Int?
    private let cleanedSnippetFingerprint: Int?
    private let snippetFingerprint: Int?
    private let hasHTMLSource: Bool
    private let senderEmailFingerprint: Int?
    private let senderDisplayNameFingerprint: Int?
    private let senderHeaderDisplayNameFingerprint: Int?
    private let senderAvatarURLFingerprint: Int?
    private let attachmentFingerprint: String

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
        senderAvatarURL: String? = nil,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot] = []
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
        self.attachmentFingerprint = MessageBubbleAttachmentSnapshot.analysisFingerprint(for: attachmentSnapshots)
    }

    func signature(
        htmlSourceSignature: String,
        contactRefreshToken: Int
    ) -> String {
        [
            bodyStorageURI ?? "",
            Self.describe(bodyTextFingerprint),
            Self.describe(chatPreviewTextFingerprint),
            Self.describe(cleanedSnippetFingerprint),
            Self.describe(snippetFingerprint),
            String(hasHTMLSource),
            "source:\(htmlSourceSignature)",
            "contacts:\(contactRefreshToken)",
            "senderEmail:\(Self.describe(senderEmailFingerprint))",
            "senderName:\(Self.describe(senderDisplayNameFingerprint))",
            "senderHeaderName:\(Self.describe(senderHeaderDisplayNameFingerprint))",
            "senderAvatar:\(Self.describe(senderAvatarURLFingerprint))",
            "attachments:\(attachmentFingerprint)"
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
        senderAvatarURL: String? = nil,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot] = []
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
            senderAvatarURL: senderAvatarURL,
            attachmentSnapshots: attachmentSnapshots
        ).signature(
            htmlSourceSignature: htmlSourceSignature,
            contactRefreshToken: contactRefreshToken
        )
    }

    /// An in-process fingerprint of `text`'s UTF-8 bytes; nil for nil, so a
    /// nil field and an empty one still differ.
    ///
    /// The signature is only ever compared within one process (the bubble's
    /// `.task(id:)` and `MessageBubbleViewModel`'s applied/requested
    /// signatures); it is never persisted or used as a cache key, so a
    /// per-process-seeded `Hasher` is enough. It replaced a SHA-256 per field
    /// hex-encoded with one `String(format:)` per byte — eight digests and
    /// about 250 format calls per mapped row, multiplied across every row of
    /// every window re-map on the main actor. The bytes are hashed rather than
    /// the `String`, whose hash folds canonically equivalent spellings
    /// together, so exactly the byte-level changes that refreshed a bubble
    /// before still do (bar a 64-bit collision).
    private static func contentFingerprint(for text: String?) -> Int? {
        guard var text else { return nil }
        var hasher = Hasher()
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        return hasher.finalize()
    }

    private static func describe(_ fingerprint: Int?) -> String {
        fingerprint.map(String.init) ?? "nil"
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
    let fallbackPreviewText: String?
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
    /// The row's persisted rich-content verdict as stored
    /// (`Message.storedRichContentVerdict`). Carried to the bubble load so it
    /// can notice a stale one, and as what it publishes when its own
    /// evaluation is undetermined (`MessageBubbleContentRequest`); views route
    /// on `knownRichContentVerdict`.
    let storedRichContentVerdict: RichContentVerdict
    /// The stored verdict where the bubble may route on it before its load
    /// publishes, else nil (`ChatMessageRowModelMapper.knownRichContentVerdict`).
    /// Deliberately absent from `loadSignatureComponents`: a verdict write
    /// (sync, the launch backfill, the refresher) must re-render the row
    /// without restarting its load.
    let knownRichContentVerdict: Bool?
    let htmlDisplayCleanupMode: HTMLContentCleanupMode
    let hasAttachments: Bool
    let attachments: [ChatMessageAttachmentModel]
    let isSendingLocalAttachments: Bool
    let hasFailedLocalAttachmentUploads: Bool
    let outboundSendDeliveryState: OutboundSendDeliveryState
    /// A just-sent row its sync echo has not replaced yet
    /// (`OutboundSendDeliveryState.localOptimisticMessageID`). Sync deletes it
    /// when the echo lands, so it is not offered as a reply target.
    let isAwaitingSyncEcho: Bool
    /// Positive evidence that Gmail holds this message: true for every row sync
    /// brought from Gmail, and for an optimistic row only once its mutation
    /// record carries Gmail's committed IDs. It gates the "Sent" receipt
    /// (`MessageSendStatusLinePolicy.line`), which must not be inferred from
    /// `outboundSendDeliveryState == .none`: the mapper also falls back to
    /// `.none` when the record fetch throws or finds no record, and an
    /// optimistic row in that state may really be "Delivery unknown" or
    /// "Not sent".
    let isConfirmedInGmail: Bool
    let forwardedDisplaySubject: String?
    let outgoingForwardedDisplayContent: ForwardedMessageDisplayContent?
    /// The shared-document links this row's content load will publish, where stored fields
    /// alone decide them (`Message.storedSharedDocumentLinks`): a non-forwarded row with a
    /// stored `chatPreviewText`. Empty for every other row, and for one with no links. The
    /// bubble shows these until its load has published
    /// (`MessageDisplayPolicy.sharedDocumentLinks`), so a row that renders before its load
    /// already has the links' URLs stripped from its text and their cards below it. Their
    /// inputs are all in `loadSignatureComponents`, so a change to them also restarts the load.
    let storedSharedDocumentLinks: [SharedDocumentLink]
    /// Precomputed so MessageBubble body recomputation does not hash message text.
    let loadSignatureComponents: MessageBubbleLoadSignatureComponents
    /// The transcript's view identity, shared by an optimistic reply and its
    /// sync echo (`ChatMessageDisplayIdentity`). Route a collection through
    /// `ChatTranscriptIdentityPolicy` before using it as `ForEach` identity.
    let displayIdentity: ChatMessageDisplayIdentity

    /// `displayIdentity` for `MessageBubbleViewModel`'s refresh-in-place
    /// decision (`MessageBubbleLoadContext.displayIdentityKey`): equal for an
    /// optimistic reply and its echo, otherwise this row's message ID, which
    /// is what the view model compared before display identity existed.
    var bubbleContentIdentityKey: String {
        switch displayIdentity {
        case .outboundSend(let optimisticMessageID):
            return "outbound:\(optimisticMessageID)"
        case .message:
            return "message:\(id)"
        }
    }

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
            attachmentSnapshots: attachments.map(\.bubbleSnapshot),
            storedRichContentVerdict: storedRichContentVerdict
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
    /// One row through the batch path, so a single row and a window resolve
    /// send state identically: in particular `isConfirmedInGmail` stays false
    /// when the record fetch fails, where `OutboundSendDeliveryState.resolve`
    /// would `try?` the failure into a `.none` indistinguishable from "accepted".
    @MainActor
    static func map(_ message: Message) -> ChatMessageRowModel {
        map([message])[0]
    }

    /// The optimistic message ID a row's RFC Message-ID encodes, decoded once
    /// per row by the batch path and handed to everything that needs it.
    ///
    /// Why: every reply this app ever sent carries an `<esc-…>` Message-ID,
    /// and `MimeBuilder.optimisticMessageID(from:)` validates by re-encoding —
    /// one `String(format:)` per byte. The mapper used to decode the same ID
    /// four times per outgoing row (echo flag, record grouping, confirmation,
    /// display identity), on the main actor, on every window re-map.
    private struct OutboundSendDecoding {
        /// Decoded from a message the user sent: shared by an optimistic row and
        /// its sync echo (`ChatMessageDisplayIdentity.outboundSend`). Nil for
        /// incoming mail, whose Message-ID its sender chose.
        let decodedOutboundSendID: String?
        /// `OutboundSendDeliveryState.localOptimisticMessageID(for:)`: the row
        /// is the local optimistic copy itself (its `id` is the decoded ID),
        /// not the echo. Must stay equivalent to that function.
        let localOptimisticMessageID: String?

        @MainActor
        init(_ message: Message) {
            guard message.isFromMe,
                  let rfcMessageID = message.messageIdValue,
                  let decoded = MimeBuilder.optimisticMessageID(from: rfcMessageID) else {
                decodedOutboundSendID = nil
                localOptimisticMessageID = nil
                return
            }
            decodedOutboundSendID = decoded
            localOptimisticMessageID = decoded == message.id ? message.id : nil
        }
    }

    @MainActor
    private static func map(
        _ message: Message,
        outboundSendDecoding: OutboundSendDecoding,
        outboundSendDeliveryState: OutboundSendDeliveryState,
        isConfirmedInGmail: Bool
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
        let fallbackPreviewText = resolvedFallbackPreviewText(
            cleanedSnippet: message.cleanedSnippet,
            snippet: message.snippet,
            chatPreviewText: message.chatPreviewTextValue,
            isFromMe: message.isFromMe,
            hasAttachments: message.hasAttachments
        )

        let attachments = message.attachmentsArray.map(map)
        let storedRichContentVerdict = message.storedRichContentVerdict
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
            fallbackPreviewText: fallbackPreviewText,
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
            storedRichContentVerdict: storedRichContentVerdict,
            knownRichContentVerdict: knownRichContentVerdict(
                stored: storedRichContentVerdict,
                chatPreviewText: message.chatPreviewTextValue,
                isFromMe: message.isFromMe,
                isForwardedEmail: message.isForwardedEmail
            ),
            htmlDisplayCleanupMode: message.htmlDisplayCleanupMode,
            hasAttachments: message.hasAttachments,
            attachments: attachments,
            isSendingLocalAttachments: message.isSendingLocalAttachments,
            hasFailedLocalAttachmentUploads: message.hasFailedLocalAttachmentUploads,
            outboundSendDeliveryState: outboundSendDeliveryState,
            isAwaitingSyncEcho: outboundSendDecoding.localOptimisticMessageID != nil,
            isConfirmedInGmail: isConfirmedInGmail,
            forwardedDisplaySubject: message.forwardedDisplaySubject,
            outgoingForwardedDisplayContent: message.outgoingForwardedDisplayContent,
            storedSharedDocumentLinks: message.storedSharedDocumentLinks,
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
                senderAvatarURL: effectiveSenderPerson?.avatarURL,
                attachmentSnapshots: attachments.map(\.bubbleSnapshot)
            ),
            displayIdentity: ChatMessageDisplayIdentity.resolve(
                isFromMe: message.isFromMe,
                decodedOutboundSendID: outboundSendDecoding.decodedOutboundSendID,
                objectID: message.objectID
            )
        )
    }

    /// The stored verdict a bubble may route on before its load publishes, or nil
    /// where the load does not publish that verdict, so the stored one predicts
    /// nothing:
    ///
    /// - a blank `chatPreviewText`: the load takes the compatibility path, whose
    ///   verdict is a different expression (network recovery, no fallback-text
    ///   term) and can differ from the stored rule's;
    /// - own rows: the load publishes not-rich for them, and the routing alone
    ///   would card an own row with a new subject in a group conversation on a
    ///   rich verdict. Their stored verdict is not-rich whenever it is current,
    ///   but an `isFromMe` that flipped since the stamp must not reach the view;
    /// - forwarded rows: a forward whose block parses publishes not-rich
    ///   whatever the stored rule says, and the bubble holds a forward off the
    ///   card until its load has published.
    ///
    /// A row whose stored text carries a shared-document link is not held back.
    /// It used to be reported as unknown, because the load would still strip the
    /// link's URL from the bubble text and append a card, and a row rendered
    /// from a known verdict would have shown the raw URL and then swapped. The
    /// row now carries those links itself (`storedSharedDocumentLinks`, for
    /// exactly the rows that pass the guards here), so it mounts with them. The
    /// one spelling that still swaps is a link whose host the row's cheap check
    /// misses (`SharedDocumentLinkExtractor.mayContainLinks`); the old gate ran
    /// the same check and did not hold that row back either.
    ///
    /// Pure and precomputed here because the bubble reads it several times per
    /// body evaluation.
    static func knownRichContentVerdict(
        stored: RichContentVerdict,
        chatPreviewText: String?,
        isFromMe: Bool,
        isForwardedEmail: Bool
    ) -> Bool? {
        guard let isRich = stored.isRich,
              !isFromMe,
              !isForwardedEmail,
              MessagePreviewText.nonEmpty(chatPreviewText) != nil else {
            return nil
        }
        return isRich
    }

    private static func resolvedFallbackPreviewText(
        cleanedSnippet: String?,
        snippet: String?,
        chatPreviewText: String?,
        isFromMe: Bool,
        hasAttachments: Bool
    ) -> String? {
        let fallback = cleanedSnippet ?? snippet
        guard isFromMe,
              hasAttachments,
              MessagePreviewText.nonEmpty(chatPreviewText) == nil else {
            return fallback
        }

        // Gmail can flatten a quote-only reply into a one-line snippet. The
        // canonical body has already been quote-stripped for chat display, so
        // clean this legacy fallback too instead of reviving quoted history as
        // an authored message bubble beside attachment-only sends.
        return MessagePreviewText.compactListText(fallback)
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

        let outboundSendDecodings = messages.map(OutboundSendDecoding.init)
        var groups: [ObjectIdentifier: CandidateGroup] = [:]
        for (message, decoding) in zip(messages, outboundSendDecodings) {
            guard let optimisticMessageID = decoding.localOptimisticMessageID,
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
        // Optimistic rows whose record proves Gmail accepted the send. A row
        // absent from here (fetch failed, record missing) falls back to `.none`
        // below but is never confirmed: the receipt fails closed.
        var confirmedInGmailObjectIDs = Set<NSManagedObjectID>()
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
                let state = OutboundSendRemoteState.deliveryState(
                    messageID: record.remoteCommittedMessageId,
                    threadID: record.remoteCommittedThreadId
                )
                statesByMessageObjectID[message.objectID] = state
                // For a record that exists, `.none` is reached only through
                // Gmail's committed IDs (a thread ID, or a non-marker message
                // ID); the pre-admission nil and every local marker resolve to
                // `.sending`, `.notSent`, or `.deliveryUnknown`.
                if state == .none {
                    confirmedInGmailObjectIDs.insert(message.objectID)
                }
            }
        }

        return zip(messages, outboundSendDecodings).map { message, decoding in
            let isOptimistic = decoding.localOptimisticMessageID != nil
            return map(
                message,
                outboundSendDecoding: decoding,
                outboundSendDeliveryState:
                    statesByMessageObjectID[message.objectID] ?? .none,
                // A non-optimistic row came from Gmail through sync.
                isConfirmedInGmail: !isOptimistic ||
                    confirmedInGmailObjectIDs.contains(message.objectID)
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
