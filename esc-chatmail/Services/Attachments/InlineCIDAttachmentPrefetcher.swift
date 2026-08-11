import Foundation
import CoreData

struct InlineCIDAttachmentPrefetchRequest: Hashable, Sendable {
    let messageId: String
    let normalizedContentIDs: Set<String>
    let attachmentIDs: Set<String>

    init(
        messageId: String,
        contentIDs: Set<String> = [],
        attachmentIDs: Set<String> = []
    ) {
        self.messageId = messageId
        self.normalizedContentIDs = Set(contentIDs.compactMap(Self.normalizedCIDTarget))
        self.attachmentIDs = Set(
            attachmentIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    var isEmpty: Bool {
        normalizedContentIDs.isEmpty && attachmentIDs.isEmpty
    }

    func merged(with other: InlineCIDAttachmentPrefetchRequest) -> InlineCIDAttachmentPrefetchRequest {
        InlineCIDAttachmentPrefetchRequest(
            messageId: messageId,
            contentIDs: normalizedContentIDs.union(other.normalizedContentIDs),
            attachmentIDs: attachmentIDs.union(other.attachmentIDs)
        )
    }

    private static func normalizedCIDTarget(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutScheme: String
        if trimmed.lowercased().hasPrefix("cid:") {
            withoutScheme = String(trimmed.dropFirst(4))
        } else {
            withoutScheme = trimmed
        }
        return EmailDocument.normalizedContentID(withoutScheme)
    }
}

enum InlineCIDAttachmentPrefetchScheduler {
    private static let pendingRequestsUserInfoKey = "inlineCIDAttachmentPrefetch.pendingRequests"
    private static let contextSaveObserverUserInfoKey = "inlineCIDAttachmentPrefetch.contextSaveObserver"

    static func schedule(
        _ request: InlineCIDAttachmentPrefetchRequest,
        in context: NSManagedObjectContext,
        prefetcher: InlineCIDAttachmentPrefetcher = .shared,
        accountWorkRegistry: AttachmentAccountWorkRegistry = .shared
    ) {
        guard !request.isEmpty else { return }
        guard let admission = accountWorkRegistry.captureAdmissionToken() else { return }

        if !context.hasChanges {
            startPrefetch(
                [request],
                admission: admission,
                prefetcher: prefetcher,
                accountWorkRegistry: accountWorkRegistry
            )
            return
        }

        if let existingObserver = context.userInfo[contextSaveObserverUserInfoKey]
            as? PendingInlineCIDAttachmentPrefetchSaveObserver,
           !existingObserver.matches(admission) {
            existingObserver.invalidate()
            context.userInfo.removeObject(forKey: pendingRequestsUserInfoKey)
            context.userInfo.removeObject(forKey: contextSaveObserverUserInfoKey)
        }

        var pending = context.userInfo[pendingRequestsUserInfoKey] as? [String: InlineCIDAttachmentPrefetchRequest] ?? [:]
        if let existing = pending[request.messageId] {
            pending[request.messageId] = existing.merged(with: request)
        } else {
            pending[request.messageId] = request
        }
        context.userInfo[pendingRequestsUserInfoKey] = pending

        if context.userInfo[contextSaveObserverUserInfoKey] == nil {
            context.userInfo[contextSaveObserverUserInfoKey] = PendingInlineCIDAttachmentPrefetchSaveObserver(
                context: context,
                prefetcher: prefetcher,
                accountWorkRegistry: accountWorkRegistry,
                admission: admission
            )
        }
    }

    static func pendingRequests(in context: NSManagedObjectContext) -> [InlineCIDAttachmentPrefetchRequest] {
        let pending = context.userInfo[pendingRequestsUserInfoKey] as? [String: InlineCIDAttachmentPrefetchRequest] ?? [:]
        return Array(pending.values)
    }

    static func pendingAdmissionToken(
        in context: NSManagedObjectContext
    ) -> AttachmentAccountWorkAdmissionToken? {
        let observer = context.userInfo[contextSaveObserverUserInfoKey]
            as? PendingInlineCIDAttachmentPrefetchSaveObserver
        return observer?.admissionToken
    }

    fileprivate static func takePendingRequests(from context: NSManagedObjectContext) -> [InlineCIDAttachmentPrefetchRequest] {
        let observer = context.userInfo[contextSaveObserverUserInfoKey]
            as? PendingInlineCIDAttachmentPrefetchSaveObserver
        defer {
            observer?.invalidate()
            context.userInfo.removeObject(forKey: pendingRequestsUserInfoKey)
            context.userInfo.removeObject(forKey: contextSaveObserverUserInfoKey)
        }

        let pending = context.userInfo[pendingRequestsUserInfoKey] as? [String: InlineCIDAttachmentPrefetchRequest] ?? [:]
        return Array(pending.values)
    }

    fileprivate static func startPrefetch(
        _ requests: [InlineCIDAttachmentPrefetchRequest],
        admission: AttachmentAccountWorkAdmissionToken,
        prefetcher: InlineCIDAttachmentPrefetcher,
        accountWorkRegistry: AttachmentAccountWorkRegistry
    ) {
        _ = accountWorkRegistry.startDetachedOperation(
            for: admission,
            priority: .utility
        ) { generation in
            guard generation.isActive else { return }
            await prefetcher.prefetch(requests, generation: generation)
        }
    }
}

private final class PendingInlineCIDAttachmentPrefetchSaveObserver: NSObject {
    private weak var context: NSManagedObjectContext?
    private let prefetcher: InlineCIDAttachmentPrefetcher
    private let accountWorkRegistry: AttachmentAccountWorkRegistry
    private let admission: AttachmentAccountWorkAdmissionToken
    private var isObserving = true

    var admissionToken: AttachmentAccountWorkAdmissionToken {
        admission
    }

    init(
        context: NSManagedObjectContext,
        prefetcher: InlineCIDAttachmentPrefetcher,
        accountWorkRegistry: AttachmentAccountWorkRegistry,
        admission: AttachmentAccountWorkAdmissionToken
    ) {
        self.context = context
        self.prefetcher = prefetcher
        self.accountWorkRegistry = accountWorkRegistry
        self.admission = admission
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: context
        )
    }

    deinit {
        invalidate()
    }

    func matches(_ admission: AttachmentAccountWorkAdmissionToken) -> Bool {
        self.admission == admission
    }

    func invalidate() {
        guard isObserving else { return }
        isObserving = false
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contextDidSave(_ _: Notification) {
        guard let context else { return }

        let requests = InlineCIDAttachmentPrefetchScheduler.takePendingRequests(from: context)
        guard !requests.isEmpty else { return }

        InlineCIDAttachmentPrefetchScheduler.startPrefetch(
            requests,
            admission: admission,
            prefetcher: prefetcher,
            accountWorkRegistry: accountWorkRegistry
        )
    }
}

actor InlineCIDAttachmentPrefetcher {
    typealias AttachmentDownload = @Sendable (NSManagedObjectID, String, NSManagedObjectContext) async -> Void

    static let shared = InlineCIDAttachmentPrefetcher()
    private static let defaultFailedAttachmentRetryInterval: TimeInterval = 30 * 60

    private struct PrefetchKey: Hashable {
        let messageId: String
        let normalizedContentID: String?
        let attachmentID: String
    }

    private struct PrefetchCandidate: @unchecked Sendable {
        let key: PrefetchKey
        let objectID: NSManagedObjectID
        let messageId: String
        let attachmentID: String
        let normalizedContentID: String?
    }

    private let makeBackgroundContext: @Sendable () -> NSManagedObjectContext
    private let downloadAttachment: AttachmentDownload
    private let failedAttachmentRetryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlightKeys: Set<PrefetchKey> = []

    init(
        coreDataStack: CoreDataStack = .shared
    ) {
        self.init(
            makeBackgroundContext: { coreDataStack.newBackgroundContext() }
        )
    }

    init(
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext,
        downloadAttachment: AttachmentDownload? = nil,
        failedAttachmentRetryInterval: TimeInterval = InlineCIDAttachmentPrefetcher.defaultFailedAttachmentRetryInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeBackgroundContext = makeBackgroundContext
        self.downloadAttachment = downloadAttachment ?? { objectID, messageId, context in
            let downloader = await MainActor.run { AttachmentDownloader.shared }
            await downloader.downloadAttachment(
                attachmentObjectID: objectID,
                messageId: messageId,
                in: context
            )
        }
        self.failedAttachmentRetryInterval = failedAttachmentRetryInterval
        self.now = now
    }

    func prefetch(_ requests: [InlineCIDAttachmentPrefetchRequest]) async {
        await prefetch(requests, generation: nil)
    }

    func prefetch(
        _ requests: [InlineCIDAttachmentPrefetchRequest],
        generation: AttachmentAccountWorkGeneration
    ) async {
        await prefetch(requests, generation: Optional(generation))
    }

    private func prefetch(
        _ requests: [InlineCIDAttachmentPrefetchRequest],
        generation: AttachmentAccountWorkGeneration?
    ) async {
        for request in requests {
            guard isActive(generation) else { return }
            await prefetch(request, generation: generation)
        }
    }

    func prefetch(_ request: InlineCIDAttachmentPrefetchRequest) async {
        await prefetch(request, generation: nil)
    }

    private func prefetch(
        _ request: InlineCIDAttachmentPrefetchRequest,
        generation: AttachmentAccountWorkGeneration?
    ) async {
        guard !request.isEmpty, isActive(generation) else { return }

        let context = makeBackgroundContext()
        let candidates = await candidates(for: request, in: context)
        guard !candidates.isEmpty, isActive(generation) else { return }

        for candidate in candidates {
            guard isActive(generation) else { return }
            guard beginPrefetch(candidate.key) else {
                Log.debug(
                    "InlineCIDAttachmentPrefetcher: duplicate eager fetch skipped for message \(candidate.messageId) attachment \(candidate.attachmentID)",
                    category: .attachment
                )
                continue
            }

            await download(
                candidate,
                in: context,
                generation: generation
            )
        }
    }

    private func download(
        _ candidate: PrefetchCandidate,
        in context: NSManagedObjectContext,
        generation: AttachmentAccountWorkGeneration?
    ) async {
        defer { finishPrefetch(candidate.key) }
        guard isActive(generation) else { return }

        Log.debug(
            "InlineCIDAttachmentPrefetcher: eager fetch started for message \(candidate.messageId) cid=\(candidate.normalizedContentID ?? "nil") attachment=\(candidate.attachmentID)",
            category: .attachment
        )
        await downloadAttachment(candidate.objectID, candidate.messageId, context)
    }

    private func isActive(_ generation: AttachmentAccountWorkGeneration?) -> Bool {
        guard !Task.isCancelled else { return false }
        return generation?.isActive ?? true
    }

    private func beginPrefetch(_ key: PrefetchKey) -> Bool {
        if inFlightKeys.contains(key) {
            return false
        }
        inFlightKeys.insert(key)
        return true
    }

    private func finishPrefetch(_ key: PrefetchKey) {
        inFlightKeys.remove(key)
    }

    private func candidates(
        for request: InlineCIDAttachmentPrefetchRequest,
        in context: NSManagedObjectContext
    ) async -> [PrefetchCandidate] {
        let referenceDate = now()
        let retryInterval = failedAttachmentRetryInterval

        return await context.perform {
            let fetchRequest = Message.fetchRequest()
            fetchRequest.predicate = MessagePredicates.id(request.messageId)
            fetchRequest.fetchLimit = 1
            fetchRequest.relationshipKeyPathsForPrefetching = ["attachments"]

            let message: Message?
            do {
                message = try context.fetch(fetchRequest).first
            } catch {
                Log.warning(
                    "InlineCIDAttachmentPrefetcher: failed to fetch message \(request.messageId) for eager inline CID fetch",
                    category: .attachment
                )
                return []
            }

            guard let message else {
                Log.debug(
                    "InlineCIDAttachmentPrefetcher: message \(request.messageId) unavailable for eager inline CID fetch",
                    category: .attachment
                )
                return []
            }

            var matchedContentIDs = Set<String>()
            var seenKeys = Set<PrefetchKey>()
            var candidates: [PrefetchCandidate] = []

            for attachment in message.attachmentsArray {
                let attachmentID = attachment.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedContentID = EmailDocument.normalizedContentID(attachment.contentId)
                let matchesContentID = normalizedContentID.map { request.normalizedContentIDs.contains($0) } ?? false
                let matchesAttachmentID = attachmentID.map { request.attachmentIDs.contains($0) } ?? false

                guard matchesContentID || matchesAttachmentID else {
                    continue
                }

                if let normalizedContentID {
                    matchedContentIDs.insert(normalizedContentID)
                }

                guard let attachmentID, !attachmentID.isEmpty else {
                    Log.debug(
                        "InlineCIDAttachmentPrefetcher: missing attachment metadata for message \(message.id) cid=\(normalizedContentID ?? "nil")",
                        category: .attachment
                    )
                    continue
                }

                guard !attachmentID.hasPrefix("local_") ||
                        attachmentID.hasPrefix("local_inline_") else {
                    continue
                }

                if Self.hasUsableLocalFile(attachment) {
                    Log.debug(
                        "InlineCIDAttachmentPrefetcher: eager hit for message \(message.id) cid=\(normalizedContentID ?? "nil") attachment=\(attachmentID)",
                        category: .attachment
                    )
                    continue
                }

                if attachment.state == .failed {
                    guard Self.canRetryFailedAttachment(
                        attachment,
                        now: referenceDate,
                        retryInterval: retryInterval
                    ) else {
                        Log.debug(
                            "InlineCIDAttachmentPrefetcher: skipping recent failed eager fetch for message \(message.id) cid=\(normalizedContentID ?? "nil") attachment=\(attachmentID); CIDSchemeHandler fallback remains available",
                            category: .attachment
                        )
                        continue
                    }

                    Log.debug(
                        "InlineCIDAttachmentPrefetcher: retrying stale failed eager fetch for message \(message.id) cid=\(normalizedContentID ?? "nil") attachment=\(attachmentID)",
                        category: .attachment
                    )
                }

                let key = PrefetchKey(
                    messageId: message.id,
                    normalizedContentID: normalizedContentID,
                    attachmentID: attachmentID
                )
                guard !seenKeys.contains(key) else {
                    continue
                }
                seenKeys.insert(key)

                candidates.append(
                    PrefetchCandidate(
                        key: key,
                        objectID: attachment.objectID,
                        messageId: message.id,
                        attachmentID: attachmentID,
                        normalizedContentID: normalizedContentID
                    )
                )
            }

            let missingContentIDs = request.normalizedContentIDs.subtracting(matchedContentIDs)
            for contentID in missingContentIDs {
                Log.debug(
                    "InlineCIDAttachmentPrefetcher: no attachment metadata for message \(message.id) cid=\(contentID)",
                    category: .attachment
                )
            }

            return candidates
        }
    }

    private static func hasUsableLocalFile(_ attachment: Attachment) -> Bool {
        guard let messageId = attachment.message?.id,
              let attachmentId = attachment.id,
              let localURL = attachment.localURL,
              AttachmentPaths.isReadableStoragePath(
                  localURL,
                  messageId: messageId,
                  attachmentId: attachmentId
              ),
              let fileURL = AttachmentPaths.fullURL(for: localURL) else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private static func canRetryFailedAttachment(
        _ attachment: Attachment,
        now: Date,
        retryInterval: TimeInterval
    ) -> Bool {
        guard retryInterval > 0 else { return false }
        guard let lastDownloadFailedAt = attachment.lastDownloadFailedAt else {
            return true
        }
        return now.timeIntervalSince(lastDownloadFailedAt) >= retryInterval
    }
}
