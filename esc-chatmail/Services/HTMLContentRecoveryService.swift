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
        do {
            // 1. Fetch full message from Gmail API
            let apiClient = await gmailAPIClientProvider()
            let gmailMessage = try await apiClient.getMessage(id: messageId, format: "full")

            // 2. Extract HTML body from MIME structure (may fetch large body parts via API)
            guard let payload = gmailMessage.payload else {
                Log.debug("No HTML body found for message \(messageId)", category: .ui)
                return .failed
            }

            let extractedHTML: String?
            if let recoveredHTML = await extractHTMLBody(from: payload, messageId: messageId, apiClient: apiClient) {
                extractedHTML = recoveredHTML
            } else {
                extractedHTML = await extractEmbeddedHTMLFromTextualBodies(
                    from: payload,
                    messageId: messageId,
                    apiClient: apiClient
                )
            }

            guard let html = extractedHTML else {
                Log.debug("No HTML body found for message \(messageId)", category: .ui)
                return .noHTML
            }

            // 3. Save to disk for future use
            _ = contentHandler.saveHTML(html, for: messageId)
            HTMLContentLoader.shared.invalidate(messageId: messageId)
            await ProcessedTextCache.shared.invalidate(messageId: messageId)
            Log.info("Recovered HTML content for message \(messageId)", category: .ui)
            return .html(html)
        } catch {
            Log.warning("Failed to recover HTML for \(messageId): \(error)", category: .ui)
            return .failed
        }
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

    private func extractEmbeddedHTMLFromTextualBodies(
        from part: MessagePart,
        messageId: String,
        apiClient: any GmailAPIClientProtocol
    ) async -> String? {
        if let decodedText = await decodedTextualBody(from: part, messageId: messageId, apiClient: apiClient),
           let extractedHTML = RawEmailSourceSanitizer.extractHTMLText(from: decodedText) {
            let trimmed = extractedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let parts = part.parts {
            for subpart in parts {
                if let html = await extractEmbeddedHTMLFromTextualBodies(
                    from: subpart,
                    messageId: messageId,
                    apiClient: apiClient
                ) {
                    return html
                }
            }
        }

        return nil
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

    /// Extracts HTML body from MIME structure
    private func extractHTMLBody(
        from part: MessagePart,
        messageId: String,
        apiClient: any GmailAPIClientProtocol
    ) async -> String? {
        let resolvedMimeType = resolvedMimeType(for: part)

        // Check this part for text/html
        if isHTMLMimeType(resolvedMimeType) {
            if let data = part.body?.data {
                return decodeBody(data, headers: part.headers)
            } else if let attachmentId = part.body?.attachmentId {
                // Large HTML body - fetch via attachment API
                return await fetchLargeBodyContent(
                    attachmentId: attachmentId,
                    messageId: messageId,
                    headers: part.headers,
                    apiClient: apiClient
                )
            }
        }

        // Recursively check child parts
        if let parts = part.parts {
            for subpart in parts {
                if let html = await extractHTMLBody(from: subpart, messageId: messageId, apiClient: apiClient) {
                    return html
                }
            }
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
