import Foundation

protocol HTMLContentRecovering: Sendable {
    func recoverHTMLContent(messageId: String) async -> String?
}

/// Service for recovering HTML content from Gmail API when local files are missing
actor HTMLContentRecoveryService: HTMLContentRecovering {
    static let shared = HTMLContentRecoveryService()

    private enum RecoveryAttemptResult: Sendable {
        case html(String)
        case noHTML
        case failed
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
    private var recoveryTasks: [String: Task<RecoveryAttemptResult, Never>] = [:]
    private var noHTMLMisses: [String: Date] = [:]
    private let noHTMLMissCacheTTL: TimeInterval

    init(
        gmailAPIClientProvider: @escaping @Sendable () async -> any GmailAPIClientProtocol = {
            await MainActor.run { GmailAPIClient.shared }
        },
        contentHandler: HTMLContentHandler = .shared,
        noHTMLMissCacheTTL: TimeInterval = 300
    ) {
        self.gmailAPIClientProvider = gmailAPIClientProvider
        self.contentHandler = contentHandler
        self.noHTMLMissCacheTTL = noHTMLMissCacheTTL
    }

    /// Recovers HTML content for a message by fetching from Gmail API.
    /// Returns the HTML content if successful, nil otherwise.
    ///
    /// This call can take arbitrarily long if the Gmail API is slow: the
    /// `await task.value` below ignores cooperative cancellation. Callers that
    /// surface this to UI should either wrap this in a `withSoftTimeout` or show
    /// a non-terminal recovery state while the underlying work completes.
    func recoverHTMLContent(messageId: String) async -> String? {
        guard !isCachedNoHTMLMiss(messageId) else {
            return nil
        }

        if let existingTask = recoveryTasks[messageId] {
            return resolvedHTML(from: await existingTask.value, messageId: messageId)
        }

        let task = Task<RecoveryAttemptResult, Never> { [self] in
            await performRecovery(messageId: messageId)
        }
        recoveryTasks[messageId] = task

        let result = await task.value
        recoveryTasks[messageId] = nil
        return resolvedHTML(from: result, messageId: messageId)
    }

    private func performRecovery(messageId: String) async -> RecoveryAttemptResult {
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
            let writeStart = CFAbsoluteTimeGetCurrent()
            if contentHandler.saveHTML(html, for: messageId) != nil {
                OriginalEmailTelemetry.log(
                    event: "original_email_db_write_completed",
                    messageId: messageId,
                    source: "provider_fetch",
                    duration: CFAbsoluteTimeGetCurrent() - writeStart,
                    detail: "storage=html_file"
                )
                await HTMLContentLoader.shared.invalidateContent(messageId: messageId)
                await ProcessedTextCache.shared.invalidate(messageId: messageId)
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
            Log.info("Recovered HTML content for message \(messageId)", category: .ui)
            return .html(html)
        } catch {
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

    private func resolvedHTML(from result: RecoveryAttemptResult, messageId: String) -> String? {
        switch result {
        case .html(let html):
            noHTMLMisses.removeValue(forKey: messageId)
            return html
        case .noHTML:
            noHTMLMisses[messageId] = Date()
            return nil
        case .failed:
            return nil
        }
    }

    private func isCachedNoHTMLMiss(_ messageId: String) -> Bool {
        guard let recordedAt = noHTMLMisses[messageId] else {
            return false
        }

        if Date().timeIntervalSince(recordedAt) < noHTMLMissCacheTTL {
            return true
        }

        noHTMLMisses.removeValue(forKey: messageId)
        return false
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
