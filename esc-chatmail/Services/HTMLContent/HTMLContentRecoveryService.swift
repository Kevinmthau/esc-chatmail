import Foundation

struct HTMLContentRecoveryAccountGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
    fileprivate let isScoped: Bool
}

protocol HTMLContentRecovering: Sendable {
    func recoverHTMLContent(messageId: String) async -> String?
    func recoverHTMLContent(
        messageId: String,
        expectedAccountGeneration: HTMLContentRecoveryAccountGeneration
    ) async -> String?
    func captureAccountGeneration() async -> HTMLContentRecoveryAccountGeneration?
    func isAccountGenerationCurrent(_ generation: HTMLContentRecoveryAccountGeneration) async -> Bool
}

extension HTMLContentRecovering {
    func recoverHTMLContent(
        messageId: String,
        expectedAccountGeneration: HTMLContentRecoveryAccountGeneration
    ) async -> String? {
        guard !expectedAccountGeneration.isScoped else { return nil }
        return await recoverHTMLContent(messageId: messageId)
    }

    func captureAccountGeneration() async -> HTMLContentRecoveryAccountGeneration? {
        HTMLContentRecoveryAccountGeneration(value: 0, isScoped: false)
    }

    func isAccountGenerationCurrent(_ generation: HTMLContentRecoveryAccountGeneration) async -> Bool {
        !generation.isScoped
    }
}

/// Service for recovering HTML content from Gmail API when local files are missing
actor HTMLContentRecoveryService: HTMLContentRecovering {
    static let shared = HTMLContentRecoveryService()

    private struct RecoveryKey: Hashable, Sendable {
        let messageId: String
        let accountGeneration: UInt64
    }

    private enum RecoveryAttemptResult: Sendable {
        case html(String)
        case noHTML
        case failed
    }

    private enum RecoveryDeadlineOutcome: Sendable {
        case completed(RecoveryAttemptResult)
        case expired
    }

    private enum HTMLRecoveryCandidateSource: Equatable {
        case htmlMimePart
        case embeddedRawSource
    }

    private struct HTMLRecoveryCandidate {
        let html: String
        let source: HTMLRecoveryCandidateSource
    }

    private let gmailAPIClientProvider: @Sendable () async -> any GmailAPIClientProtocol
    private let contentHandler: HTMLContentHandler
    private var recoveryTasks: [RecoveryKey: Task<RecoveryAttemptResult, Never>] = [:]
    /// Work that outlived its caller-facing deadline remains registered until
    /// it actually unwinds. Account teardown can therefore cancel and drain a
    /// provider that ignores cooperative cancellation instead of losing the
    /// handle when the timed wrapper returns.
    private var deadlineWorkTasks: [UUID: Task<RecoveryAttemptResult, Never>] = [:]
    private var noHTMLMisses: [RecoveryKey: Date] = [:]
    private var acceptsAccountWork = true
    private var accountGeneration: UInt64 = 0
    private let noHTMLMissCacheTTL: TimeInterval
    /// Hard upper bound on a single Gmail recovery fetch. A slow or hung fetch is
    /// abandoned past this (and its in-flight URLSession request cancelled), so a
    /// user-facing open can't be stranded and a later retry starts fresh.
    private let recoveryNetworkTimeout: TimeInterval

    init(
        gmailAPIClientProvider: @escaping @Sendable () async -> any GmailAPIClientProtocol = {
            await MainActor.run { GmailAPIClient.shared }
        },
        contentHandler: HTMLContentHandler = .shared,
        noHTMLMissCacheTTL: TimeInterval = 300,
        // Generous enough that a legitimately slow recovery (large body part over a
        // poor mobile network) still completes, while still bounding a hung fetch.
        recoveryNetworkTimeout: TimeInterval = 30
    ) {
        self.gmailAPIClientProvider = gmailAPIClientProvider
        self.contentHandler = contentHandler
        self.noHTMLMissCacheTTL = noHTMLMissCacheTTL
        self.recoveryNetworkTimeout = recoveryNetworkTimeout
    }

    /// Recovers HTML content for a message by fetching from Gmail API.
    /// Returns the HTML content if successful, nil otherwise.
    ///
    /// The fetch is hard-bounded by `recoveryNetworkTimeout` (see `performRecovery`),
    /// so this call returns within that deadline even if the Gmail API stalls.
    /// Concurrent callers for the same message still share a single in-flight fetch.
    func recoverHTMLContent(messageId: String) async -> String? {
        await recoverHTMLContent(messageId: messageId, expectedAccountGeneration: nil)
    }

    func recoverHTMLContent(
        messageId: String,
        expectedAccountGeneration: HTMLContentRecoveryAccountGeneration
    ) async -> String? {
        await recoverHTMLContent(
            messageId: messageId,
            expectedAccountGeneration: Optional(expectedAccountGeneration)
        )
    }

    func captureAccountGeneration() -> HTMLContentRecoveryAccountGeneration? {
        guard acceptsAccountWork else { return nil }
        return HTMLContentRecoveryAccountGeneration(
            value: accountGeneration,
            isScoped: true
        )
    }

    func isAccountGenerationCurrent(_ generation: HTMLContentRecoveryAccountGeneration) -> Bool {
        acceptsAccountWork &&
            generation.isScoped &&
            generation.value == accountGeneration
    }

    private func recoverHTMLContent(
        messageId: String,
        expectedAccountGeneration: HTMLContentRecoveryAccountGeneration?
    ) async -> String? {
        guard acceptsAccountWork,
              expectedAccountGeneration.map({
                  $0.isScoped && $0.value == accountGeneration
              }) ?? true,
              let htmlGeneration = contentHandler.captureAccountGeneration() else {
            return nil
        }
        let key = RecoveryKey(messageId: messageId, accountGeneration: accountGeneration)

        guard !isCachedNoHTMLMiss(key) else {
            return nil
        }

        if let existingTask = recoveryTasks[key] {
            return resolvedHTML(
                from: await existingTask.value,
                key: key,
                htmlGeneration: htmlGeneration
            )
        }

        let task = Task<RecoveryAttemptResult, Never> { [self] in
            await performRecovery(
                messageId: messageId,
                key: key,
                htmlGeneration: htmlGeneration
            )
        }
        recoveryTasks[key] = task

        let result = await task.value
        recoveryTasks[key] = nil
        return resolvedHTML(from: result, key: key, htmlGeneration: htmlGeneration)
    }

    /// Rejects new recovery work, invalidates its generation, and waits for
    /// even cancellation-insensitive provider calls to unwind before account
    /// HTML is deleted.
    func closeAccountWorkAndAwait() async {
        acceptsAccountWork = false
        accountGeneration &+= 1
        noHTMLMisses.removeAll()
        let activeTasks = Array(recoveryTasks.values)
        let activeDeadlineTasks = Array(deadlineWorkTasks.values)
        activeTasks.forEach { $0.cancel() }
        activeDeadlineTasks.forEach { $0.cancel() }
        for task in activeTasks {
            _ = await task.value
        }
        for task in activeDeadlineTasks {
            _ = await task.value
        }
        recoveryTasks.removeAll()
        deadlineWorkTasks.removeAll()
    }

    func reopenAccountWork() {
        accountGeneration &+= 1
        noHTMLMisses.removeAll()
        acceptsAccountWork = true
    }

    /// Hard-bounds the recovery fetch. On timeout the in-flight fetch is cancelled
    /// and we return `.failed` — which is *not* cached as a no-HTML miss, so the
    /// next attempt re-fetches instead of re-attaching to abandoned work.
    private func performRecovery(
        messageId: String,
        key: RecoveryKey,
        htmlGeneration: HTMLContentAccountGeneration
    ) async -> RecoveryAttemptResult {
        guard isCurrent(key, htmlGeneration: htmlGeneration) else {
            return .failed
        }
        let workID = UUID()
        let workTask = Task<RecoveryAttemptResult, Never> { [self] in
            await performRecoveryToCompletion(
                messageId: messageId,
                key: key,
                htmlGeneration: htmlGeneration
            )
        }
        deadlineWorkTasks[workID] = workTask

        let deadlineOutcome = await Self.awaitResult(
            of: workTask,
            timeout: recoveryNetworkTimeout
        )

        switch deadlineOutcome {
        case .completed(let result):
            deadlineWorkTasks.removeValue(forKey: workID)
            return result

        case .expired:
            // Keep the handle registered while cancellation-insensitive work
            // unwinds. A small observer removes it during normal operation;
            // account teardown snapshots and awaits the same task directly.
            Task { [weak self] in
                _ = await workTask.value
                await self?.finishDeadlineWork(workID)
            }
            OriginalEmailTelemetry.log(
                event: "original_email_raw_fetch_failed",
                messageId: messageId,
                source: "provider_fetch",
                detail: "provider=gmail format=full failure_reason=recovery_timed_out_\(Int(recoveryNetworkTimeout.rounded()))s"
            )
            Log.warning("Recovery for message \(messageId) timed out after \(Int(recoveryNetworkTimeout.rounded()))s", category: .ui)
            return .failed
        }
    }

    private func finishDeadlineWork(_ id: UUID) {
        deadlineWorkTasks.removeValue(forKey: id)
    }

    /// Races an already-registered recovery task against its deadline and the
    /// caller's cancellation. Unlike `withDeadline`, ownership of `task`
    /// remains with the actor so a later account transition can still drain it.
    private nonisolated static func awaitResult(
        of task: Task<RecoveryAttemptResult, Never>,
        timeout: TimeInterval
    ) async -> RecoveryDeadlineOutcome {
        let timeoutNanoseconds = timeout * 1_000_000_000
        guard timeoutNanoseconds.isFinite,
              timeoutNanoseconds < Double(UInt64.max) else {
            return .completed(await task.value)
        }

        let gate = SingleFireContinuationGate<RecoveryDeadlineOutcome>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let settled = gate.install(continuation) {
                    continuation.resume(returning: settled)
                    return
                }

                Task {
                    gate.resume(returning: .completed(await task.value))
                }
                Task {
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(0, timeoutNanoseconds))
                    )
                    task.cancel()
                    gate.resume(returning: .expired)
                }
            }
        } onCancel: {
            task.cancel()
            gate.resume(returning: .expired)
        }
    }

    private func performRecoveryToCompletion(
        messageId: String,
        key: RecoveryKey,
        htmlGeneration: HTMLContentAccountGeneration
    ) async -> RecoveryAttemptResult {
        guard isCurrent(key, htmlGeneration: htmlGeneration) else {
            return .failed
        }
        let fetchStart = CFAbsoluteTimeGetCurrent()
        OriginalEmailTelemetry.log(
            event: "original_email_raw_fetch_started",
            messageId: messageId,
            source: "provider_fetch",
            detail: "provider=gmail format=full"
        )

        do {
            // 1. Fetch full message from Gmail API
            let apiClient = await gmailAPIClientProvider()
            let gmailMessage = try await apiClient.getMessage(id: messageId, format: "full")
            guard isCurrent(key, htmlGeneration: htmlGeneration) else {
                return .failed
            }
            OriginalEmailTelemetry.log(
                event: "original_email_raw_fetch_completed",
                messageId: messageId,
                source: "provider_fetch",
                duration: CFAbsoluteTimeGetCurrent() - fetchStart,
                detail: "provider=gmail format=full"
            )

            // 2. Extract HTML body from MIME structure (may fetch large body parts via API)
            let decodeStart = CFAbsoluteTimeGetCurrent()
            OriginalEmailTelemetry.log(
                event: "original_email_decode_started",
                messageId: messageId,
                source: "provider_fetch",
                detail: "stage=gmail_mime_extract"
            )

            guard let payload = gmailMessage.payload else {
                OriginalEmailTelemetry.log(
                    event: "original_email_decode_failed",
                    messageId: messageId,
                    source: "provider_fetch",
                    duration: CFAbsoluteTimeGetCurrent() - decodeStart,
                    detail: "stage=gmail_mime_extract failure_reason=missing_payload"
                )
                Log.debug("No HTML body found for message \(messageId)", category: .ui)
                return .failed
            }

            let htmlMimeCandidates = await collectHTMLCandidates(
                from: payload,
                messageId: messageId,
                apiClient: apiClient,
                includeHTMLMimeParts: true,
                includeEmbeddedRawSource: false
            )
            guard isCurrent(key, htmlGeneration: htmlGeneration) else {
                return .failed
            }

            let embeddedRawSourceCandidates: [HTMLRecoveryCandidate]
            let resolvedHTML = bestMeaningfulHTMLCandidate(from: htmlMimeCandidates)
            if resolvedHTML == nil {
                embeddedRawSourceCandidates = await collectHTMLCandidates(
                    from: payload,
                    messageId: messageId,
                    apiClient: apiClient,
                    includeHTMLMimeParts: false,
                    includeEmbeddedRawSource: true
                )
                guard isCurrent(key, htmlGeneration: htmlGeneration) else {
                    return .failed
                }
            } else {
                embeddedRawSourceCandidates = []
            }

            guard let html = resolvedHTML ?? bestMeaningfulHTMLCandidate(from: embeddedRawSourceCandidates) else {
                OriginalEmailTelemetry.log(
                    event: "original_email_decode_failed",
                    messageId: messageId,
                    source: "provider_fetch",
                    duration: CFAbsoluteTimeGetCurrent() - decodeStart,
                    detail: "stage=gmail_mime_extract failure_reason=no_html_candidate"
                )
                Log.debug("No HTML body found for message \(messageId)", category: .ui)
                return .noHTML
            }

            OriginalEmailTelemetry.log(
                event: "original_email_decode_completed",
                messageId: messageId,
                source: "provider_fetch",
                duration: CFAbsoluteTimeGetCurrent() - decodeStart,
                detail: "stage=gmail_mime_extract"
            )

            // 3. Save to disk for future use
            // Capture every dependent cache epoch *before* the write, then
            // re-check our own generation. A transition that lands after this
            // point leaves the captured tokens stale, so each invalidation
            // below no-ops instead of evicting the reopened account's caches;
            // a transition that landed before it is caught by `isCurrent`.
            // The loader context is captured unscoped on purpose:
            // `captureInvalidationAccountContext(expectedAccountGeneration:)`
            // validates the token against `HTMLContentLoader.shared`'s own
            // `HTMLContentHandler`, and an injected recovery handler pointing
            // at a different Messages directory carries a token that handler
            // would always reject. In production both handlers resolve to the
            // same directory boundary, so the captured epoch is the same one
            // `htmlGeneration` came from.
            guard let invalidationContext = await HTMLContentLoader.shared
                .captureInvalidationAccountContext(),
                let processedTextGeneration = await ProcessedTextCache.shared
                    .captureAccountGeneration(),
                isCurrent(key, htmlGeneration: htmlGeneration) else {
                return .failed
            }

            let writeStart = CFAbsoluteTimeGetCurrent()
            if contentHandler.saveHTML(
                html,
                for: messageId,
                expectedGeneration: htmlGeneration
            ) != nil {
                OriginalEmailTelemetry.log(
                    event: "original_email_db_write_completed",
                    messageId: messageId,
                    source: "provider_fetch",
                    duration: CFAbsoluteTimeGetCurrent() - writeStart,
                    detail: "storage=html_file"
                )
                await HTMLContentLoader.shared.invalidateContent(
                    messageId: messageId,
                    accountContext: invalidationContext
                )
                // `invalidateContent` already evicts RenderedMessageCache under
                // the captured generation. ProcessedTextCache's own rendered hop
                // is unscoped, so it must stay off here or it reintroduces the
                // cross-account eviction this capture exists to prevent.
                await ProcessedTextCache.shared.invalidate(
                    messageId: messageId,
                    expectedAccountGeneration: processedTextGeneration,
                    invalidatesRenderedMessage: false
                )
                guard isCurrent(key, htmlGeneration: htmlGeneration) else {
                    return .failed
                }
                let sourceSignature = CanonicalEmailContent(
                    html: html,
                    plainText: nil,
                    sourceKind: .recoveredHTML,
                    sourceLocation: .recoveredHTML
                ).sourceSignature
                await MainActor.run {
                    HTMLContentLoader.postContentSourceDidChange(
                        messageId: messageId,
                        sourceSignature: sourceSignature
                    )
                }
            } else {
                OriginalEmailTelemetry.log(
                    event: "original_email_db_write_failed",
                    messageId: messageId,
                    source: "provider_fetch",
                    duration: CFAbsoluteTimeGetCurrent() - writeStart,
                    detail: "storage=html_file failure_reason=save_html_failed"
                )
            }
            guard isCurrent(key, htmlGeneration: htmlGeneration) else {
                return .failed
            }
            Log.info("Recovered HTML content for message \(messageId)", category: .ui)
            return .html(html)
        } catch {
            // Cancellation means the recovery deadline elapsed (or the caller went
            // away). `performRecovery` already logs the timeout, so don't double-count
            // it here as a Gmail fetch failure.
            if Task.isCancelled {
                return .failed
            }
            let errorCode = redactedErrorCode(error)
            OriginalEmailTelemetry.log(
                event: "original_email_raw_fetch_failed",
                messageId: messageId,
                source: "provider_fetch",
                duration: CFAbsoluteTimeGetCurrent() - fetchStart,
                detail: "provider=gmail format=full failure_reason=\(errorCode)"
            )
            Log.warning("Failed to recover HTML for \(messageId): \(errorCode)", category: .ui)
            return .failed
        }
    }

    private func redactedErrorCode(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "url_error_\(urlError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    private func resolvedHTML(
        from result: RecoveryAttemptResult,
        key: RecoveryKey,
        htmlGeneration: HTMLContentAccountGeneration
    ) -> String? {
        guard isCurrent(key, htmlGeneration: htmlGeneration) else {
            return nil
        }
        switch result {
        case .html(let html):
            noHTMLMisses.removeValue(forKey: key)
            return html
        case .noHTML:
            noHTMLMisses[key] = Date()
            return nil
        case .failed:
            return nil
        }
    }

    private func isCachedNoHTMLMiss(_ key: RecoveryKey) -> Bool {
        guard let recordedAt = noHTMLMisses[key] else {
            return false
        }

        if Date().timeIntervalSince(recordedAt) < noHTMLMissCacheTTL {
            return true
        }

        noHTMLMisses.removeValue(forKey: key)
        return false
    }

    private func isCurrent(
        _ key: RecoveryKey,
        htmlGeneration: HTMLContentAccountGeneration
    ) -> Bool {
        acceptsAccountWork &&
            key.accountGeneration == accountGeneration &&
            contentHandler.isAccountGenerationCurrent(htmlGeneration)
    }

    private func collectHTMLCandidates(
        from part: MessagePart,
        messageId: String,
        apiClient: any GmailAPIClientProtocol,
        includeHTMLMimeParts: Bool,
        includeEmbeddedRawSource: Bool
    ) async -> [HTMLRecoveryCandidate] {
        guard !isAttachmentContentPart(part) else {
            return []
        }

        var candidates: [HTMLRecoveryCandidate] = []
        let resolvedMimeType = resolvedMimeType(for: part)
        let isHTMLPart = isHTMLMimeType(resolvedMimeType)
        let shouldExtractHTMLPart = includeHTMLMimeParts && isHTMLPart
        let shouldExtractEmbeddedRawSource = includeEmbeddedRawSource && !isHTMLPart && canContainEmbeddedRawSourceHTML(resolvedMimeType)

        if (shouldExtractHTMLPart || shouldExtractEmbeddedRawSource),
           let decodedBody = await decodedTextualBody(from: part, messageId: messageId, apiClient: apiClient) {
            if isHTMLPart {
                appendCandidate(
                    decodedBody,
                    source: .htmlMimePart,
                    to: &candidates
                )
            } else if let extractedHTML = RawEmailSourceSanitizer.extractHTMLText(from: decodedBody) {
                appendCandidate(
                    extractedHTML,
                    source: .embeddedRawSource,
                    to: &candidates
                )
            }
        }

        if let parts = part.parts {
            for subpart in parts {
                candidates.append(contentsOf: await collectHTMLCandidates(
                    from: subpart,
                    messageId: messageId,
                    apiClient: apiClient,
                    includeHTMLMimeParts: includeHTMLMimeParts,
                    includeEmbeddedRawSource: includeEmbeddedRawSource
                ))
            }
        }

        return candidates
    }

    private func appendCandidate(
        _ html: String,
        source: HTMLRecoveryCandidateSource,
        to candidates: inout [HTMLRecoveryCandidate]
    ) {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        candidates.append(HTMLRecoveryCandidate(html: trimmed, source: source))
    }

    private func decodedTextualBody(
        from part: MessagePart,
        messageId: String,
        apiClient: any GmailAPIClientProtocol
    ) async -> String? {
        if let data = part.body?.data {
            return decodeBody(data, headers: part.headers)
        }

        if let attachmentId = part.body?.attachmentId {
            return await fetchLargeBodyContent(
                attachmentId: attachmentId,
                messageId: messageId,
                headers: part.headers,
                apiClient: apiClient
            )
        }

        return nil
    }

    /// Fetches large body content via the attachment API
    /// Gmail returns body parts larger than ~25KB with attachmentId instead of inline data
    private func fetchLargeBodyContent(
        attachmentId: String,
        messageId: String,
        headers: [MessageHeader]?,
        apiClient: any GmailAPIClientProtocol
    ) async -> String? {
        do {
            let attachmentData = try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
            let text = String(decoding: attachmentData, as: UTF8.self)
            return decodeTransferEncoding(text, headers: headers)
        } catch {
            Log.warning("Failed to fetch large body \(attachmentId) for message \(messageId): \(error)", category: .ui)
            return nil
        }
    }

    /// Decodes Gmail's URL-safe Base64 encoding
    private func decodeBody(_ data: String, headers: [MessageHeader]?) -> String? {
        guard let decodedData = decodeBase64Data(data) else {
            return nil
        }
        let text = String(decoding: decodedData, as: UTF8.self)
        return decodeTransferEncoding(text, headers: headers)
    }

    private func decodeBase64Data(_ data: String) -> Data? {
        // Gmail uses URL-safe base64 (RFC 4648) and may include incidental whitespace/newlines.
        // Be permissive here; decode failures would prevent HTML recovery and leave emails blank.
        let base64String = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")

        var paddedBase64 = base64String
        let remainder = base64String.count % 4
        if remainder > 0 {
            paddedBase64 = base64String + String(repeating: "=", count: 4 - remainder)
        }

        guard let decodedData = Data(base64Encoded: paddedBase64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }

        return decodedData
    }

    private func resolvedMimeType(for part: MessagePart) -> String? {
        if let directMimeType = part.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directMimeType.isEmpty {
            return directMimeType
        }

        guard let contentType = part.headers?
            .first(where: { $0.name.lowercased() == "content-type" })?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentType.isEmpty else {
            return nil
        }

        return contentType
    }

    private func isHTMLMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mimeType.isEmpty else {
            return false
        }

        return mimeType.hasPrefix("text/html")
    }

    private func canContainEmbeddedRawSourceHTML(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mimeType.isEmpty else {
            return true
        }

        return mimeType.hasPrefix("text/") || mimeType.hasPrefix("message/")
    }

    private func isAttachmentContentPart(_ part: MessagePart) -> Bool {
        let trimmedFilename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFilename.isEmpty {
            return true
        }

        let contentDisposition = part.headers?
            .first(where: { $0.name.lowercased() == "content-disposition" })?
            .value
            .lowercased() ?? ""

        return contentDisposition.contains("attachment")
    }

    private func bestMeaningfulHTMLCandidate(from candidates: [HTMLRecoveryCandidate]) -> String? {
        let scoredCandidates = candidates.enumerated().compactMap { index, candidate -> (html: String, source: HTMLRecoveryCandidateSource, score: Int, order: Int)? in
            let html = candidate.html.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !html.isEmpty,
                  HTMLMeaningfulContentChecker.hasMeaningfulContent(html) else {
                return nil
            }

            return (
                html: html,
                source: candidate.source,
                score: scoreHTMLCandidate(html, source: candidate.source),
                order: index
            )
        }

        let sortedCandidates = scoredCandidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.order < rhs.order
            }

        return sortedCandidates.first { $0.source == .htmlMimePart }?.html
            ?? sortedCandidates.first?.html
    }

    private func scoreHTMLCandidate(_ html: String, source: HTMLRecoveryCandidateSource) -> Int {
        var score = 100_000
        let lowercased = html.lowercased()
        let renderableHTML = HTMLMeaningfulContentChecker.renderableHTML(from: html)
        let visibleTextLength = normalizedVisibleTextLength(in: renderableHTML)

        score += min(visibleTextLength, 20_000)
        if visibleTextLength > 0 {
            score += 500
        }

        if lowercased.contains("<img") {
            score += 1_000
        }
        if lowercased.contains("<svg") {
            score += 1_000
        }
        if lowercased.contains("background-image") {
            score += 750
        }
        if lowercased.contains("<table") {
            score += 250
        }

        if lowercased.contains("<!doctype") {
            score += 200
        }
        if lowercased.contains("<html") {
            score += 200
        }
        if lowercased.contains("</html>") {
            score += 100
        }
        if lowercased.contains("<body") {
            score += 200
        }
        if lowercased.contains("</body>") {
            score += 100
        }

        if source == .htmlMimePart {
            score += 25
        }

        return score
    }

    private func normalizedVisibleTextLength(in html: String) -> Int {
        let text = TextProcessing.extractPlainText(from: html)
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count
    }

    private func decodeTransferEncoding(_ text: String, headers: [MessageHeader]?) -> String {
        let encoding = headers?.first { $0.name.lowercased() == "content-transfer-encoding" }?.value.lowercased()
        if encoding?.contains("quoted-printable") == true {
            return QuotedPrintableDecoder.decode(text)
        }
        if encoding == nil, looksQuotedPrintable(text) {
            return QuotedPrintableDecoder.decode(text)
        }
        return text
    }

    private func looksQuotedPrintable(_ text: String) -> Bool {
        if text.contains("=\r\n") || text.contains("=\n") {
            return true
        }
        let lower = text.lowercased()
        if lower.contains("=3d") || lower.contains("=3c") || lower.contains("=3e") {
            return true
        }
        return false
    }
}
