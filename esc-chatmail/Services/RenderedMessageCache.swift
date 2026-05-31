import Foundation

struct RenderedMessageKey: Hashable, Sendable {
    let messageId: String
    let sourceSignature: String
}

struct RenderedMessageVariantKey: Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

struct RenderedMessageChatBubbleText: Equatable, Sendable {
    let plainText: String?
    let hasRichContent: Bool
    let quotedParts: [QuotedPart]

    init(plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart] = []) {
        self.plainText = plainText
        self.hasRichContent = hasRichContent
        self.quotedParts = quotedParts
    }
}

struct RenderedMessageSnapshotMetadata: Equatable, Sendable {
    let snapshotCacheKey: String
    let displayHeight: Double
    let pixelScale: Double
    let createdAt: Date
}

struct RenderedMessageArtifacts: Sendable {
    let sourceSignature: String
    var canonicalPlainText: String?
    var chatBubbleTextByVariant: [RenderedMessageVariantKey: RenderedMessageChatBubbleText] = [:]
    var htmlAnalysisByVariant: [RenderedMessageVariantKey: MessageBubbleHTMLAnalysis] = [:]
    var richContentClassificationByVariant: [RenderedMessageVariantKey: Bool] = [:]
    var previewSourceByVariant: [RenderedMessageVariantKey: EmailPreviewSource] = [:]
    var previewRenderModelByVariant: [RenderedMessageVariantKey: EmailPreviewRenderModel] = [:]
    var wrappedPreviewHTMLByVariant: [RenderedMessageVariantKey: HTMLPreviewPayload] = [:]
    var wrappedOriginalHTMLByVariant: [RenderedMessageVariantKey: String] = [:]
    var snapshotMetadataByVariant: [RenderedMessageVariantKey: RenderedMessageSnapshotMetadata] = [:]
}

enum RenderedMessageArtifactType: String, Sendable {
    case canonicalPlainText
    case chatBubbleText
    case htmlAnalysis
    case richContentClassification
    case previewSource
    case previewRenderModel
    case wrappedPreviewHTML
    case wrappedOriginalHTML
    case snapshotMetadata
}

enum RenderedMessageInvalidationReason: String, Sendable {
    case sourceSignatureChanged
    case explicit
    case memoryWarning
    case capacity
}

struct RenderedMessageCacheStatistics: Equatable, Sendable {
    var hits = 0
    var misses = 0
    var producedArtifacts = 0
    var invalidations = 0
    var duplicateWorkAvoided = 0
    var currentEntryCount = 0
}

private struct RenderedMessageCacheEntry: Sendable {
    var artifacts: RenderedMessageArtifacts
    var accessSequence: UInt64
    var estimatedSizeBytes: Int
}

private struct RenderedMessageInFlightKey: Hashable, Sendable {
    let messageKey: RenderedMessageKey
    let artifactType: RenderedMessageArtifactType
    let variantKey: RenderedMessageVariantKey?
}

private struct AnyRenderedArtifactBox: @unchecked Sendable {
    let value: Any?
}

private struct RenderedMessageInvalidationSnapshot: Equatable, Sendable {
    let globalGeneration: UInt64
    let messageGeneration: UInt64
    let sourceGeneration: UInt64
}

private struct RenderedMessageInFlightWork: Sendable {
    let id: UUID
    let task: Task<AnyRenderedArtifactBox, Never>
    let invalidationSnapshot: RenderedMessageInvalidationSnapshot
}

actor RenderedMessageCache: MemoryWarningHandler {
    static let shared = RenderedMessageCache(startsMemoryWarningObserver: true)

    private let countLimit: Int
    private let memoryLimitBytes: Int
    private let memoryObserver = MemoryWarningObserver()
    private var entries: [RenderedMessageKey: RenderedMessageCacheEntry] = [:]
    private var keysByMessageId: [String: Set<RenderedMessageKey>] = [:]
    private var inFlight: [RenderedMessageInFlightKey: RenderedMessageInFlightWork] = [:]
    private var globalInvalidationGeneration: UInt64 = 0
    private var messageInvalidationGenerations: [String: UInt64] = [:]
    private var sourceInvalidationGenerations: [RenderedMessageKey: UInt64] = [:]
    private var accessSequence: UInt64 = 0
    private var statistics = RenderedMessageCacheStatistics()

    init(
        countLimit: Int = 500,
        memoryLimitBytes: Int = 20 * 1024 * 1024,
        startsMemoryWarningObserver: Bool = false
    ) {
        self.countLimit = countLimit
        self.memoryLimitBytes = memoryLimitBytes

        if startsMemoryWarningObserver {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryObserver.start(handler: self)
            }
        }
    }

    func canonicalPlainText(
        messageId: String,
        sourceSignature: String,
        producer: @escaping @Sendable () async -> String?
    ) async -> String? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .canonicalPlainText,
            variantKey: nil,
            lookup: { $0.canonicalPlainText },
            store: { $0.canonicalPlainText = $1 },
            producer: producer
        )
    }

    func chatBubbleText(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> RenderedMessageChatBubbleText?
    ) async -> RenderedMessageChatBubbleText? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .chatBubbleText,
            variantKey: variantKey,
            lookup: { $0.chatBubbleTextByVariant[variantKey] },
            store: { $0.chatBubbleTextByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func cachedChatBubbleText(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey
    ) -> RenderedMessageChatBubbleText? {
        cachedValue(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .chatBubbleText,
            variantKey: variantKey,
            lookup: { $0.chatBubbleTextByVariant[variantKey] }
        )
    }

    func storeChatBubbleText(
        _ value: RenderedMessageChatBubbleText,
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey
    ) {
        storeValue(
            value,
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .chatBubbleText,
            variantKey: variantKey
        ) { artifacts, value in
            artifacts.chatBubbleTextByVariant[variantKey] = value
        }
    }

    func htmlAnalysis(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> MessageBubbleHTMLAnalysis?
    ) async -> MessageBubbleHTMLAnalysis? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .htmlAnalysis,
            variantKey: variantKey,
            lookup: { $0.htmlAnalysisByVariant[variantKey] },
            store: { $0.htmlAnalysisByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func richContentClassification(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> Bool?
    ) async -> Bool? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .richContentClassification,
            variantKey: variantKey,
            lookup: { $0.richContentClassificationByVariant[variantKey] },
            store: { $0.richContentClassificationByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func cachedRichContentClassification(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey
    ) -> Bool? {
        cachedValue(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .richContentClassification,
            variantKey: variantKey,
            lookup: { $0.richContentClassificationByVariant[variantKey] }
        )
    }

    func storeRichContentClassification(
        _ value: Bool,
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey
    ) {
        storeValue(
            value,
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .richContentClassification,
            variantKey: variantKey
        ) { artifacts, value in
            artifacts.richContentClassificationByVariant[variantKey] = value
        }
    }

    func previewSource(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> EmailPreviewSource?
    ) async -> EmailPreviewSource? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .previewSource,
            variantKey: variantKey,
            lookup: { $0.previewSourceByVariant[variantKey] },
            store: { $0.previewSourceByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func previewRenderModel(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> EmailPreviewRenderModel?
    ) async -> EmailPreviewRenderModel? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .previewRenderModel,
            variantKey: variantKey,
            lookup: { $0.previewRenderModelByVariant[variantKey] },
            store: { $0.previewRenderModelByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func wrappedPreviewHTML(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> HTMLPreviewPayload?
    ) async -> HTMLPreviewPayload? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .wrappedPreviewHTML,
            variantKey: variantKey,
            lookup: { $0.wrappedPreviewHTMLByVariant[variantKey] },
            store: { $0.wrappedPreviewHTMLByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func wrappedOriginalHTML(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey,
        producer: @escaping @Sendable () async -> String?
    ) async -> String? {
        await cachedOrProduce(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .wrappedOriginalHTML,
            variantKey: variantKey,
            lookup: { $0.wrappedOriginalHTMLByVariant[variantKey] },
            store: { $0.wrappedOriginalHTMLByVariant[variantKey] = $1 },
            producer: producer
        )
    }

    func recordSnapshotMetadata(
        _ metadata: RenderedMessageSnapshotMetadata,
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey
    ) {
        storeValue(
            metadata,
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .snapshotMetadata,
            variantKey: variantKey
        ) { artifacts, value in
            artifacts.snapshotMetadataByVariant[variantKey] = value
        }
    }

    func snapshotMetadata(
        messageId: String,
        sourceSignature: String,
        variantKey: RenderedMessageVariantKey
    ) -> RenderedMessageSnapshotMetadata? {
        cachedValue(
            messageId: messageId,
            sourceSignature: sourceSignature,
            artifactType: .snapshotMetadata,
            variantKey: variantKey,
            lookup: { $0.snapshotMetadataByVariant[variantKey] }
        )
    }

    func artifacts(messageId: String, sourceSignature: String) -> RenderedMessageArtifacts? {
        let key = RenderedMessageKey(messageId: messageId, sourceSignature: sourceSignature)
        guard let entry = entries[key] else {
            return nil
        }

        touch(key)
        return entry.artifacts
    }

    func invalidate(
        messageId: String,
        sourceSignature: String? = nil,
        reason: RenderedMessageInvalidationReason = .explicit
    ) {
        let keys = keysByMessageId[messageId] ?? []
        let keysToRemove = keys.filter { key in
            sourceSignature.map { key.sourceSignature == $0 } ?? true
        }
        remove(keysToRemove, reason: reason)
        cancelInFlight(messageId: messageId, sourceSignature: sourceSignature)
        advanceInvalidationGeneration(messageId: messageId, sourceSignature: sourceSignature)
    }

    func clear() {
        let keys = Set(entries.keys)
        remove(keys, reason: .explicit)
        cancelAllInFlight()
        advanceGlobalInvalidationGeneration()
    }

    func handleMemoryWarning() async {
        let keys = Set(entries.keys)
        remove(keys, reason: .memoryWarning)
        cancelAllInFlight()
        advanceGlobalInvalidationGeneration()
        Log.info("RenderedMessageCache cleared due to memory warning", category: .ui)
    }

    func getStatistics() -> RenderedMessageCacheStatistics {
        var snapshot = statistics
        snapshot.currentEntryCount = entries.count
        return snapshot
    }

    private func cachedOrProduce<T: Sendable>(
        messageId: String,
        sourceSignature: String,
        artifactType: RenderedMessageArtifactType,
        variantKey: RenderedMessageVariantKey?,
        lookup: (RenderedMessageArtifacts) -> T?,
        store: (inout RenderedMessageArtifacts, T) -> Void,
        producer: @escaping @Sendable () async -> T?
    ) async -> T? {
        let key = RenderedMessageKey(messageId: messageId, sourceSignature: sourceSignature)

        if let cached = cachedValue(
            key: key,
            artifactType: artifactType,
            variantKey: variantKey,
            lookup: lookup
        ) {
            return cached
        }

        let inFlightKey = RenderedMessageInFlightKey(
            messageKey: key,
            artifactType: artifactType,
            variantKey: variantKey
        )

        if let work = inFlight[inFlightKey] {
            statistics.duplicateWorkAvoided += 1
            log(
                event: "duplicate-work-avoided",
                key: key,
                artifactType: artifactType,
                variantKey: variantKey
            )
            let box = await work.task.value
            guard isCurrent(work.invalidationSnapshot, for: key) else {
                return nil
            }
            return box.value as? T
        }

        let task = Task<AnyRenderedArtifactBox, Never> {
            AnyRenderedArtifactBox(value: await producer())
        }
        let work = RenderedMessageInFlightWork(
            id: UUID(),
            task: task,
            invalidationSnapshot: invalidationSnapshot(for: key)
        )
        inFlight[inFlightKey] = work

        let box = await work.task.value
        let isCurrentWork = inFlight[inFlightKey]?.id == work.id
        if isCurrentWork {
            inFlight.removeValue(forKey: inFlightKey)
        }

        guard isCurrentWork,
              isCurrent(work.invalidationSnapshot, for: key) else {
            return nil
        }

        guard let produced = box.value as? T else {
            return nil
        }

        storeValue(
            produced,
            key: key,
            artifactType: artifactType,
            variantKey: variantKey,
            store: store
        )
        statistics.producedArtifacts += 1
        return produced
    }

    private func cachedValue<T>(
        messageId: String,
        sourceSignature: String,
        artifactType: RenderedMessageArtifactType,
        variantKey: RenderedMessageVariantKey?,
        lookup: (RenderedMessageArtifacts) -> T?
    ) -> T? {
        let key = RenderedMessageKey(messageId: messageId, sourceSignature: sourceSignature)
        return cachedValue(
            key: key,
            artifactType: artifactType,
            variantKey: variantKey,
            lookup: lookup
        )
    }

    private func cachedValue<T>(
        key: RenderedMessageKey,
        artifactType: RenderedMessageArtifactType,
        variantKey: RenderedMessageVariantKey?,
        lookup: (RenderedMessageArtifacts) -> T?
    ) -> T? {
        guard let entry = entries[key],
              let value = lookup(entry.artifacts) else {
            statistics.misses += 1
            log(event: "cache-miss", key: key, artifactType: artifactType, variantKey: variantKey)
            return nil
        }

        touch(key)
        statistics.hits += 1
        log(event: "cache-hit", key: key, artifactType: artifactType, variantKey: variantKey)
        return value
    }

    private func storeValue<T>(
        _ value: T,
        messageId: String,
        sourceSignature: String,
        artifactType: RenderedMessageArtifactType,
        variantKey: RenderedMessageVariantKey?,
        store: (inout RenderedMessageArtifacts, T) -> Void
    ) {
        let key = RenderedMessageKey(messageId: messageId, sourceSignature: sourceSignature)
        storeValue(
            value,
            key: key,
            artifactType: artifactType,
            variantKey: variantKey,
            store: store
        )
    }

    private func storeValue<T>(
        _ value: T,
        key: RenderedMessageKey,
        artifactType: RenderedMessageArtifactType,
        variantKey: RenderedMessageVariantKey?,
        store: (inout RenderedMessageArtifacts, T) -> Void
    ) {
        var artifacts = entries[key]?.artifacts ?? RenderedMessageArtifacts(sourceSignature: key.sourceSignature)
        store(&artifacts, value)

        accessSequence &+= 1
        entries[key] = RenderedMessageCacheEntry(
            artifacts: artifacts,
            accessSequence: accessSequence,
            estimatedSizeBytes: Self.estimatedSizeBytes(for: artifacts)
        )
        keysByMessageId[key.messageId, default: []].insert(key)
        enforceLimits()
        log(event: "artifact-produced", key: key, artifactType: artifactType, variantKey: variantKey)
    }

    private func touch(_ key: RenderedMessageKey) {
        guard var entry = entries[key] else { return }
        accessSequence &+= 1
        entry.accessSequence = accessSequence
        entries[key] = entry
    }

    private func enforceLimits() {
        while entries.count > countLimit {
            evictLeastRecentlyUsed()
        }

        while currentEstimatedSizeBytes() > memoryLimitBytes, !entries.isEmpty {
            evictLeastRecentlyUsed()
        }
    }

    private func evictLeastRecentlyUsed() {
        guard let key = entries.min(by: { $0.value.accessSequence < $1.value.accessSequence })?.key else {
            return
        }
        remove([key], reason: .capacity)
    }

    private func cancelInFlight(messageId: String, sourceSignature: String?) {
        let keysToCancel = inFlight.keys.filter { key in
            key.messageKey.messageId == messageId &&
                (sourceSignature.map { key.messageKey.sourceSignature == $0 } ?? true)
        }

        for key in keysToCancel {
            inFlight[key]?.task.cancel()
            inFlight.removeValue(forKey: key)
        }
    }

    private func cancelAllInFlight() {
        for work in inFlight.values {
            work.task.cancel()
        }
        inFlight.removeAll()
    }

    private func invalidationSnapshot(for key: RenderedMessageKey) -> RenderedMessageInvalidationSnapshot {
        RenderedMessageInvalidationSnapshot(
            globalGeneration: globalInvalidationGeneration,
            messageGeneration: messageInvalidationGenerations[key.messageId] ?? 0,
            sourceGeneration: sourceInvalidationGenerations[key] ?? 0
        )
    }

    private func isCurrent(
        _ snapshot: RenderedMessageInvalidationSnapshot,
        for key: RenderedMessageKey
    ) -> Bool {
        snapshot == invalidationSnapshot(for: key)
    }

    private func advanceInvalidationGeneration(messageId: String, sourceSignature: String?) {
        if let sourceSignature {
            let key = RenderedMessageKey(messageId: messageId, sourceSignature: sourceSignature)
            sourceInvalidationGenerations[key, default: 0] &+= 1
        } else {
            messageInvalidationGenerations[messageId, default: 0] &+= 1
            sourceInvalidationGenerations = sourceInvalidationGenerations.filter { entry in
                entry.key.messageId != messageId
            }
        }
    }

    private func advanceGlobalInvalidationGeneration() {
        globalInvalidationGeneration &+= 1
        messageInvalidationGenerations.removeAll()
        sourceInvalidationGenerations.removeAll()
    }

    private func remove<S: Sequence>(
        _ keys: S,
        reason: RenderedMessageInvalidationReason
    ) where S.Element == RenderedMessageKey {
        var removedKeys: [RenderedMessageKey] = []
        for key in keys {
            if entries.removeValue(forKey: key) != nil {
                removedKeys.append(key)
                keysByMessageId[key.messageId]?.remove(key)
                if keysByMessageId[key.messageId]?.isEmpty == true {
                    keysByMessageId.removeValue(forKey: key.messageId)
                }
            }
        }

        guard !removedKeys.isEmpty else { return }
        statistics.invalidations += removedKeys.count
        for key in removedKeys {
            logInvalidation(key: key, reason: reason)
        }
    }

    private func currentEstimatedSizeBytes() -> Int {
        entries.values.reduce(0) { $0 + $1.estimatedSizeBytes }
    }

    private static func estimatedSizeBytes(for artifacts: RenderedMessageArtifacts) -> Int {
        var size = 96
        size += stringSize(artifacts.sourceSignature)
        size += stringSize(artifacts.canonicalPlainText)
        size += artifacts.chatBubbleTextByVariant.reduce(0) { total, pair in
            total + stringSize(pair.key.rawValue) + stringSize(pair.value.plainText) + quotedPartsSize(pair.value.quotedParts) + 32
        }
        size += artifacts.htmlAnalysisByVariant.count * 256
        size += artifacts.richContentClassificationByVariant.count * 48
        size += artifacts.previewSourceByVariant.reduce(0) { total, pair in
            total + stringSize(pair.key.rawValue) + previewSourceSize(pair.value)
        }
        size += artifacts.previewRenderModelByVariant.reduce(0) { total, pair in
            total + stringSize(pair.key.rawValue) + previewRenderModelSize(pair.value)
        }
        size += artifacts.wrappedPreviewHTMLByVariant.reduce(0) { total, pair in
            total + stringSize(pair.key.rawValue) + stringSize(pair.value.html) + stringSize(pair.value.previewCacheKey)
        }
        size += artifacts.wrappedOriginalHTMLByVariant.reduce(0) { total, pair in
            total + stringSize(pair.key.rawValue) + stringSize(pair.value)
        }
        size += artifacts.snapshotMetadataByVariant.reduce(0) { total, pair in
            total + stringSize(pair.key.rawValue) + stringSize(pair.value.snapshotCacheKey) + 48
        }
        return size
    }

    private static func previewSourceSize(_ source: EmailPreviewSource) -> Int {
        stringSize(source.messageId) +
            stringSize(source.sourceSignature) +
            stringSize(source.canonicalHTML) +
            stringSize(source.plainText) +
            stringSize(source.extractedText) +
            source.extractedImages.reduce(0) { total, image in
                total +
                    stringSize(image.sourceURL) +
                    stringSize(image.descriptor) +
                    stringSize(image.followingText) +
                    48
            } +
            256
    }

    private static func previewRenderModelSize(_ model: EmailPreviewRenderModel) -> Int {
        switch model {
        case .calendarInvite:
            return 512
        case .newsletter(let model):
            return stringSize(model.title) +
                stringSize(model.subtitle) +
                stringSize(model.snippet) +
                stringSize(model.heroImageURL) +
                stringSize(model.sourceLabel) +
                stringSize(model.sourceDomain) +
                128
        case .transactional(let model):
            return stringSize(model.title) +
                stringSize(model.subtitle) +
                stringSize(model.amount) +
                stringSize(model.status) +
                stringSize(model.actionLabel) +
                stringSize(model.detailLine) +
                stringSize(model.imageURL) +
                stringSize(model.sourceLabel) +
                stringSize(model.sourceDomain) +
                128
        case .netlifyDeploy:
            return 512
        case .html(let payload):
            return stringSize(payload.html) + stringSize(payload.previewCacheKey) + 64
        }
    }

    private static func quotedPartsSize(_ quotedParts: [QuotedPart]) -> Int {
        quotedParts.reduce(0) { total, part in
            total + stringSize(part.text) + stringSize(part.attribution) + 32
        }
    }

    private static func stringSize(_ value: String?) -> Int {
        value?.utf8.count ?? 0
    }

    private static func stringSize(_ value: String) -> Int {
        value.utf8.count
    }

    private func log(
        event: String,
        key: RenderedMessageKey,
        artifactType: RenderedMessageArtifactType,
        variantKey: RenderedMessageVariantKey?
    ) {
        var components = [
            "RenderedMessageCache",
            "event=\(event)",
            "message=\(key.messageId)",
            "sourceSignature=\(key.sourceSignature)",
            "artifact=\(artifactType.rawValue)"
        ]
        if let variantKey {
            components.append("variant=\(variantKey.rawValue)")
        }
        Log.diagnostic(.htmlPreview, level: .debug, components.joined(separator: " "), category: .ui)
    }

    private func logInvalidation(
        key: RenderedMessageKey,
        reason: RenderedMessageInvalidationReason
    ) {
        Log.diagnostic(
            .htmlPreview,
            level: .debug,
            "RenderedMessageCache event=invalidated message=\(key.messageId) sourceSignature=\(key.sourceSignature) reason=\(reason.rawValue)",
            category: .ui
        )
    }
}
