import XCTest
@testable import esc_chatmail

final class LogRedactionTests: XCTestCase {

    // MARK: - redact(email:)

    func testRedactEmail_standard_keepsFirstCharAndDomain() {
        XCTAssertEqual(Log.redact(email: "jane.doe@example.com"), "j***@example.com")
    }

    func testRedactEmail_singleCharLocal_masksEntireLocalPart() {
        XCTAssertEqual(Log.redact(email: "a@example.com"), "***@example.com")
    }

    func testRedactEmail_emptyLocalPart_masksLocalPart() {
        XCTAssertEqual(Log.redact(email: "@example.com"), "***@example.com")
    }

    func testRedactEmail_doesNotLeakLocalPartBeyondFirstChar() {
        let redacted = Log.redact(email: "supersecretuser@example.com")
        XCTAssertFalse(redacted.contains("supersecretuser"))
        XCTAssertFalse(redacted.contains("upersecret"))
        XCTAssertTrue(redacted.hasPrefix("s***@"))
    }

    func testRedactEmail_nonEmailValue_isFullyMasked() {
        XCTAssertEqual(Log.redact(email: "not-an-email"), "<redacted>")
    }

    func testRedactEmail_nilAndEmpty_returnNonePlaceholder() {
        XCTAssertEqual(Log.redact(email: nil), "<none>")
        XCTAssertEqual(Log.redact(email: ""), "<none>")
    }

    // MARK: - redact(address:)

    func testRedactAddress_headerWithDisplayName_dropsNameAndRedactsEmail() {
        let redacted = Log.redact(address: "Jane Doe <jane@example.com>")
        XCTAssertEqual(redacted, "j***@example.com")
        XCTAssertFalse(redacted.contains("Jane"))
        XCTAssertFalse(redacted.contains("Doe"))
    }

    func testRedactAddress_bareEmail_isRedacted() {
        XCTAssertEqual(Log.redact(address: "jane@example.com"), "j***@example.com")
    }

    func testRedactAddress_malformedAngleBracketHeader_isFullyMasked() {
        let redacted = Log.redact(address: "Jane <jane@example.com (Jane Doe)>")

        XCTAssertEqual(redacted, "<redacted>")
        XCTAssertFalse(redacted.contains("Jane"))
        XCTAssertFalse(redacted.contains("Doe"))
        XCTAssertFalse(redacted.contains("example.com"))
    }

    func testRedactAddress_noParseableEmail_isFullyMasked() {
        XCTAssertEqual(Log.redact(address: "unknown"), "<redacted>")
    }

    func testRedactAddress_nilAndEmpty_returnNonePlaceholder() {
        XCTAssertEqual(Log.redact(address: nil), "<none>")
        XCTAssertEqual(Log.redact(address: ""), "<none>")
    }

    // MARK: - redact(url:)

    func testRedactURL_stripsPathQueryAndFragment() {
        let url = URL(string: "https://example.com/reset?token=secret#frag")!
        let redacted = Log.redact(url: url)
        XCTAssertEqual(redacted, "https://example.com/...")
        XCTAssertFalse(redacted.contains("token"))
        XCTAssertFalse(redacted.contains("secret"))
    }

    func testRedactURL_hostOnly_keepsSchemeAndHost() {
        XCTAssertEqual(Log.redact(url: URL(string: "https://example.com")!), "https://example.com")
    }

    func testRedactURL_trailingSlashOnly_treatedAsNoDetail() {
        XCTAssertEqual(Log.redact(url: URL(string: "https://example.com/")!), "https://example.com")
    }

    func testRedactURL_queryWithoutPath_marksDetail() {
        XCTAssertEqual(Log.redact(url: URL(string: "https://example.com?token=secret")!), "https://example.com/...")
    }

    func testRedactURL_fileURL_dropsPathThatMayEncodePII() {
        let url = URL(string: "file:///var/mobile/Containers/Avatars/amFuZUBleGFtcGxlLmNvbQ.jpg")!
        let redacted = Log.redact(url: url)
        XCTAssertEqual(redacted, "file:...")
        XCTAssertFalse(redacted.contains("Avatars"))
        XCTAssertFalse(redacted.contains("amFuZUB"))
    }

    func testRedactURL_nilURL_returnsNonePlaceholder() {
        let url: URL? = nil
        XCTAssertEqual(Log.redact(url: url), "<none>")
    }

    // MARK: - redact(url:) String overload

    func testRedactURLString_validURL_isRedacted() {
        XCTAssertEqual(Log.redact(url: "https://example.com/path?q=1"), "https://example.com/...")
    }

    func testRedactURLString_nilAndEmpty_returnNonePlaceholder() {
        XCTAssertEqual(Log.redact(url: String?.none), "<none>")
        XCTAssertEqual(Log.redact(url: ""), "<none>")
    }

    // MARK: - hashIdentifier(_:)

    func testHashIdentifierIsStableAndDoesNotExposeRawValue() {
        let rawID = "gmail-message-id-123456789"

        let firstHash = Log.hashIdentifier(rawID)
        let secondHash = Log.hashIdentifier(rawID)

        XCTAssertEqual(firstHash, secondHash)
        XCTAssertEqual(firstHash.count, 16)
        XCTAssertFalse(firstHash.contains(rawID))
        XCTAssertNotEqual(firstHash, rawID)
    }

    // MARK: - redact(error:)

    func testRedactErrorOmitsLocalizedDescription() {
        let error = NSError(
            domain: "SensitiveDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "token=secret@example.com"]
        )

        let redacted = Log.redact(error: error)

        XCTAssertEqual(redacted, "SensitiveDomain#42")
        XCTAssertFalse(redacted.contains("secret@example.com"))
        XCTAssertFalse(redacted.contains("token="))
    }

    // MARK: - Static production log guard

    func testProductionLogsDoNotAddRawSensitiveInterpolationPatterns() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoot = repoRoot.appendingPathComponent("esc-chatmail", isDirectory: true)

        var findings = Set<String>()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: productionRoot,
                includingPropertiesForKeys: nil
            )
        )

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL)
            let relativePath = fileURL.path.replacingOccurrences(
                of: repoRoot.path + "/",
                with: ""
            )

            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmedLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.containsSensitiveRawLogInterpolation(trimmedLine) else { continue }
                findings.insert("\(relativePath)|\(trimmedLine)")
            }
        }

        let newFindings = findings.subtracting(Self.legacyRawSensitiveLogFingerprints)
        XCTAssertTrue(
            newFindings.isEmpty,
            "New raw sensitive log interpolation(s) must use Log.redact(...) or Log.hashIdentifier(...):\n"
                + newFindings.sorted().joined(separator: "\n")
        )
    }

    private static func containsSensitiveRawLogInterpolation(_ line: String) -> Bool {
        guard line.contains("Log.") else { return false }
        guard !line.contains("Log.redact"), !line.contains("Log.hashIdentifier") else {
            return false
        }

        if line.contains("localizedDescription") {
            return true
        }

        let sensitiveIdentifiers = [
            "messageid",
            "threadid",
            "attachmentid",
            "sender",
            "recipient",
            "email",
            "token",
            "url"
        ]

        return interpolationContents(in: line).contains { interpolation in
            let value = interpolation.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedValue = value.lowercased()
            if lowercasedValue.hasSuffix(".count") {
                return false
            }

            if ["error", "apierror", "urlerror", "nserror"].contains(value) {
                return true
            }

            return sensitiveIdentifiers.contains { lowercasedValue.contains($0) }
        }
    }

    private static func interpolationContents(in line: String) -> [String] {
        var values: [String] = []
        var searchIndex = line.startIndex

        while let openingRange = line.range(of: "\\(", range: searchIndex..<line.endIndex) {
            var depth = 1
            var currentIndex = openingRange.upperBound
            var closingIndex: String.Index?

            while currentIndex < line.endIndex {
                let character = line[currentIndex]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        closingIndex = currentIndex
                        break
                    }
                }
                currentIndex = line.index(after: currentIndex)
            }

            guard let closingIndex else { break }
            values.append(String(line[openingRange.upperBound..<closingIndex]))
            searchIndex = line.index(after: closingIndex)
        }

        return values
    }

    private static let legacyRawSensitiveLogFingerprints: Set<String> = [
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to clear Core Data: \\(error)\", category: .coreData)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to clear keychain: \\(error)\", category: .auth)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to clear tokens: \\(error)\", category: .auth)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to disconnect Google session during fresh install cleanup: \\(error.localizedDescription)\", category: .auth)",
        "esc-chatmail/Services/API/GmailAPIClient+History.swift|Log.error(\"History request failed (attempt \\(attempt + 1)/\\(retries)): \\(error.localizedDescription)\", category: .api)",
        "esc-chatmail/Services/API/GmailAPIClient+History.swift|Log.error(\"Token refresh failed during 401 recovery: \\(error.localizedDescription)\", category: .api)",
        "esc-chatmail/Services/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed archive for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed markRead for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed markUnread for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed star for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed unstar for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.debug(\"Download already in progress for attachment: \\(attachmentId)\", category: .attachment)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.debug(\"Retrying attachment \\(attachmentId) in \\(delay) seconds (attempt \\(attempts)/\\(maxRetryAttempts))\", category: .attachment)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.debug(\"Skipping download for local attachment: \\(attachmentId)\", category: .attachment)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.error(\"Failed to download attachment \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.error(\"Failed to save attachment updates for \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.error(\"Failed to save failed attachment state for \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.error(\"Failed to save local attachment state for \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.warning(\"Attachment \\(attachmentId) failed after \\(maxRetryAttempts) attempts\", category: .attachment)",
        "esc-chatmail/Services/AttachmentDownloader.swift|Log.warning(\"Failed to save original attachment file for ID: \\(attachmentId)\", category: .attachment)",
        "esc-chatmail/Services/AuthSession.swift|Log.warning(\"Failed to restore previous sign-in: \\(error.localizedDescription)\", category: .auth)",
        "esc-chatmail/Services/Background/BackgroundMessageProcessor.swift|Log.warning(\"Failed to fetch message \\(messageId) in background: \\(error.localizedDescription)\", category: .background)",
        "esc-chatmail/Services/Background/BackgroundSyncErrorHandler.swift|Log.error(\"URL error during background sync: \\(urlError)\", category: .background)",
        "esc-chatmail/Services/CIDSchemeHandler.swift|Log.debug(\"CIDSchemeHandler: Empty Content-ID from URL: \\(url)\", category: .ui)",
        "esc-chatmail/Services/CIDSchemeHandler.swift|Log.debug(\"CIDSchemeHandler: On-demand fetch failed for attachment \\(attachmentId): \\(error.localizedDescription)\", category: .ui)",
        "esc-chatmail/Services/Caching/AttachmentCacheActor.swift|Log.debug(\"Skipping downsample for \\(attachmentId): invalid target size \\(targetSize)\", category: .attachment)",
        "esc-chatmail/Services/Caching/DiskImageCache.swift|Log.debug(\"Failed to read cache file attributes: \\(fileURL.lastPathComponent)\", category: .general)",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.info(\"Background send cancelled for optimistic message \\(optimisticMessageID)\", category: .message)",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.info(\"Background send completed after cancellation for optimistic message \\(optimisticMessageID)\", category: .message)",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.warning(\"Post-send sync failed - sent message will appear on next sync: \\(error.localizedDescription)\", category: .sync)",
        "esc-chatmail/Services/ContactsResolver.swift|Log.warning(\"Contacts authorization failed for batch lookup: \\(error)\", category: .general)",
        "esc-chatmail/Services/ContactsResolver.swift|Log.warning(\"Contacts authorization failed for prewarm: \\(error)\", category: .general)",
        "esc-chatmail/Services/ContactsResolver.swift|Log.warning(\"Contacts authorization failed: \\(error)\", category: .general)",
        "esc-chatmail/Services/Conversation/ConversationMerger.swift|Log.debug(\"Merging \\(losers.count) conversation(s) for gmThreadId: \\(threadId.prefix(16))...\", category: .conversation)",
        "esc-chatmail/Services/Conversation/ConversationMerger.swift|Log.debug(\"Skipping gmThreadId merge for \\(threadId.prefix(16))... to preserve forwarded conversation split\", category: .conversation)",
        "esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift|Log.diagnostic(.conversationRollups, \"Excluding self: \\(email)\", category: .conversation)",
        "esc-chatmail/Services/ConversationCreationSerializer.swift|Log.error(\"Failed to create conversation: \\(error)\", category: .coreData)",
        "esc-chatmail/Services/ConversationCreationSerializer.swift|Log.error(\"Failed to save new conversation: \\(error)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataBackupManager.swift|Log.warning(\"Failed to remove old backup: \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift|Log.info(\"Created backup before migration recovery: \\(backupURL.path)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift|Log.info(\"Created backup before store reset: \\(backupURL.path)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift|Log.warning(\"Core Data load attempt \\(currentAttempts) failed with recoverable error: \\(error)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataSaveOperations.swift|Log.debug(\"  - Detail: \\(detailedError.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataSaveOperations.swift|Log.error(\"Core Data save error in \\(caller): \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/NSManagedObjectContext+Perform.swift|Log.warning(\"count failed for \\(type): \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/NSManagedObjectContext+Perform.swift|Log.warning(\"fetchAll failed for \\(type): \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/NSManagedObjectContext+Perform.swift|Log.warning(\"fetchFirst failed for \\(type): \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/EmailTextProcessor.swift|Log.debug(\"Failed to create attributed string from HTML: \\(error)\", category: .message)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorClassifier.swift|Log.debug(\"File operation \\(operation) failed at \\(url.lastPathComponent) (ignored)\", category: .general)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorClassifier.swift|Log.error(\"File operation \\(operation) failed at \\(url.lastPathComponent)\", category: .general, error: error)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorClassifier.swift|Log.warning(\"File operation \\(operation) failed at \\(url.lastPathComponent), may retry\", category: .general)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.debug(\"Failed to get file size for \\(url.lastPathComponent)\", category: category)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.debug(\"Failed to list contents of \\(url.lastPathComponent)\", category: category)",
        "esc-chatmail/Services/GmailAPIClient.swift|Log.error(\"Request failed (attempt \\(attempt + 1)/\\(retries)): \\(error.localizedDescription)\", category: .api)",
        "esc-chatmail/Services/GmailAPIClient.swift|Log.error(\"Token refresh failed during 401 recovery: \\(error.localizedDescription)\", category: .api)",
        "esc-chatmail/Services/HTMLContentHandler.swift|Log.debug(\"Failed to read creation date for \\(fileURL.lastPathComponent)\", category: .general)",
        "esc-chatmail/Services/HTMLContentHandler.swift|Log.error(\"Failed to load HTML from \\(url)\", category: .general, error: error)",
        "esc-chatmail/Services/HTMLContentHandler.swift|Log.error(\"Failed to save HTML for message \\(messageId)\", category: .general, error: error)",
        "esc-chatmail/Services/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: original preferHTML content not meaningful for \\(messageId) (len=\\(safeHTML.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: sanitized HTML not meaningful for \\(messageId) (len=\\(sanitizedHTML.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: wrapped HTML not meaningful for \\(messageId) (len=\\(wrapped.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: wrapped original preferHTML not meaningful for \\(messageId) (len=\\(wrapped.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader.swift|Log.debug(\"loadContent: All HTML methods failed for \\(messageId), falling back to plain text (bodyText=\\(bodyText?.count ?? 0) chars)\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader.swift|Log.debug(\"loadContent: Method 1 (messageId file) rejected by wrappedHTMLIfMeaningful for \\(messageId) (htmlLen=\\(html.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader.swift|Log.debug(\"loadContent: Method 2 (storageURI) rejected by wrappedHTMLIfMeaningful for \\(messageId) (htmlLen=\\(html.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentLoader.swift|Log.debug(\"loadContent: Method 3 (rawSourceHTML) rejected by wrappedHTMLIfMeaningful for \\(messageId) (htmlLen=\\(html.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContentRecoveryService.swift|Log.debug(\"No HTML body found for message \\(messageId)\", category: .ui)",
        "esc-chatmail/Services/HTMLContentRecoveryService.swift|Log.info(\"Recovered HTML content for message \\(messageId)\", category: .ui)",
        "esc-chatmail/Services/HTMLContentRecoveryService.swift|Log.warning(\"Failed to fetch large body \\(attachmentId) for message \\(messageId): \\(error)\", category: .ui)",
        "esc-chatmail/Services/HTMLContentRecoveryService.swift|Log.warning(\"Failed to recover HTML for \\(messageId): \\(errorCode)\", category: .ui)",
        "esc-chatmail/Services/HTMLContentRecoveryService.swift|Log.warning(\"Recovery for message \\(messageId) timed out after \\(Int(recoveryNetworkTimeout.rounded()))s\", category: .ui)",
        "esc-chatmail/Services/MessageProcessor.swift|Log.debug(\"ATTACH_DEBUG Part: mime=\\(part.mimeType ?? \"nil\") file=\\(part.filename ?? \"nil\") attachId=\\(hasAttachmentId) size=\\(part.body?.size ?? 0)\", category: .sync)",
        "esc-chatmail/Services/MessageProcessor.swift|Log.debug(\"MIME_DEBUG \\(indent)[\\(messageId)] mime=\\(mime) file='\\(filename)' attachId=\\(attachId != \"none\" ? \"YES\" : \"no\") size=\\(size) parts=\\(partCount)\", category: .sync)",
        "esc-chatmail/Services/MessageProcessor.swift|Log.warning(\"Failed to fetch large body \\(attachmentId) for message \\(messageId): \\(error)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/PendingActionProcessor.swift|Log.debug(\"Failed to clear local modification for message \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/PendingActionProcessor.swift|Log.error(\"Failed to process action: \\(error)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/PendingActionQueries.swift|Log.error(\"Failed to cancel pending action for message \\(messageId)\", category: .sync, error: error)",
        "esc-chatmail/Services/PendingActionsManager.swift|Log.error(\"Failed to save pending action \\(type.rawValue) for message \\(messageId) - action will not be queued\", category: .sync)",
        "esc-chatmail/Services/Security/TokenManager+Refresh.swift|Log.warning(\"Token refresh attempt \\(attempt + 1) failed: \\(error)\", category: .auth)",
        "esc-chatmail/Services/Sync/AccountPersister.swift|Log.error(\"Failed to save history ID after all retries. Last error: \\(lastError?.localizedDescription ?? \"unknown\")\", category: .sync)",
        "esc-chatmail/Services/Sync/AccountPersister.swift|Log.warning(\"Failed to save history ID (attempt 1): \\(error.localizedDescription)\", category: .sync)",
        "esc-chatmail/Services/Sync/AccountPersister.swift|Log.warning(\"Failed to save history ID (attempt \\(attempt)): \\(error.localizedDescription)\", category: .sync)",
        "esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift|Log.warning(\"Failed to refresh send-as aliases; using cached aliases: \\(error.localizedDescription)\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Found local message \\(messageId), applying label removal\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Message \\(messageId) not found locally - skipping\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Removed label '\\(labelId)' from message \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Skipping server label \\(operation) for message \\(messageId) - local changes pending\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.warning(\"Only found \\(foundLabels) of \\(labelIds.count) labels for message \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/Sync/MessagePersister.swift|Log.error(\"Failed to create message \\(processedMessage.id): \\(error)\", category: .sync)",
        "esc-chatmail/Services/Sync/Persistence/MessagePersister+Helpers.swift|Log.error(\"Failed to create attachment for message \\(message.id): \\(error)\", category: .coreData)",
        "esc-chatmail/Services/Sync/Persistence/MessagePersister+Participants.swift|Log.error(\"Failed to create participant for message \\(message.id): \\(error)\", category: .coreData)",
        "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|Log.debug(\"WebView navigation failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|Log.debug(\"WebView preview height measurement failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|Log.debug(\"WebView provisional navigation failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/FullEmailReaderWebView.swift|Log.debug(\"WebView navigation failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/FullEmailReaderWebView.swift|Log.debug(\"WebView provisional navigation failed: \\(error)\", category: .ui)"
    ]
}
