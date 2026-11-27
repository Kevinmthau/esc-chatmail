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

    /// RFC 5322 allows a comment inside the angle-addr, and the address
    /// parser leaves it out of the address (`EmailNormalizer.scanMailbox`),
    /// so this is redacted as the address alone. An angle-addr whose comment
    /// never closes has no address, and is masked whole. Either way no part
    /// of the name is logged.
    func testRedactAddress_commentInsideAngleAddr_logsNoPartOfTheName() {
        let cases = [
            ("Jane <jane@example.com (Jane Doe)>", "j***@example.com"),
            ("Jane <jane@example.com (Jane Doe>", "<redacted>")
        ]
        for (header, expected) in cases {
            let redacted = Log.redact(address: header)

            XCTAssertEqual(redacted, expected, header)
            XCTAssertFalse(redacted.contains("Jane"), header)
            XCTAssertFalse(redacted.contains("Doe"), header)
        }
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
        // Revert-check: this file lives at esc-chatmailTests/Logging/, so the repo
        // root is three directories up. Two hops land on esc-chatmailTests/, and
        // appending "esc-chatmail" there does not exist — the enumerator then
        // yields nothing and this guard passes without reading app sources.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionRoot = repoRoot.appendingPathComponent("esc-chatmail", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: productionRoot.path),
            "App sources must exist at \(productionRoot.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: productionRoot
                    .appendingPathComponent("Services/Sync/AccountPersister.swift")
                    .path
            ),
            "Scan root must be the app target, not esc-chatmailTests/"
        )

        var findings = Set<String>()
        var scannedSwiftFiles = 0
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: productionRoot,
                includingPropertiesForKeys: nil
            )
        )

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            scannedSwiftFiles += 1
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = fileURL.path.replacingOccurrences(
                of: repoRoot.path + "/",
                with: ""
            )

            for statement in Self.logStatements(in: contents) {
                guard Self.containsSensitiveRawLogInterpolation(statement) else { continue }
                findings.insert("\(relativePath)|\(statement)")
            }
        }

        XCTAssertGreaterThan(
            scannedSwiftFiles,
            100,
            "Expected to scan app Swift sources; scanned \(scannedSwiftFiles) files at \(productionRoot.path)"
        )

        let allowlist = Self.legacyRawSensitiveLogFingerprints
        let unexpected = findings.subtracting(allowlist)
        let stale = allowlist.subtracting(findings)
        var mismatch: [String] = []
        if !unexpected.isEmpty {
            mismatch.append(
                "New raw sensitive log interpolation(s) must use Log.redact(...) or Log.hashIdentifier(...):\n"
                    + unexpected.sorted().joined(separator: "\n")
            )
        }
        if !stale.isEmpty {
            mismatch.append(
                "Stale fingerprint(s) no longer match production sources and must be removed:\n"
                    + stale.sorted().joined(separator: "\n")
            )
        }
        XCTAssertTrue(mismatch.isEmpty, mismatch.joined(separator: "\n\n"))
    }

    /// Revert-check: fails if `logStatements` reads one line at a time again (the value on
    /// the second line is never seen), if `opensLogCall` goes back to `Log.` alone (the
    /// `ScopedLogger` call is never seen), or if the `id` / `message.id` rule is dropped.
    func testScan_readsCallsThatSpanLines_scopedLoggers_andMessageIDs() {
        let source = """
        Log.warning(
            "Full-message recovery did not contain synthesized inline attachment \\(requestedAttachmentId)",
            category: .attachment
        )
        self.log.error("Duplicate Message id \\(id) in local DB")
        log.warning("Failed to process message: \\(message.id)")
        Log.warning("Attempted to commit unknown transaction \\(transaction.id)", category: .sync)
        Log.error(
            "Failed to create attachment for message \\(Log.hashIdentifier(message.id))",
            category: .coreData,
            error: error
        )
        let unrelated = (messageId)
        """

        let statements = Self.logStatements(in: source)
        XCTAssertEqual(statements.count, 5, "\(statements)")
        XCTAssertEqual(
            statements[0],
            "Log.warning( \"Full-message recovery did not contain synthesized inline attachment \\(requestedAttachmentId)\", category: .attachment )"
        )

        let flagged = statements.filter(Self.containsSensitiveRawLogInterpolation)
        XCTAssertEqual(flagged.count, 3, "\(flagged)")
        XCTAssertTrue(flagged.contains { $0.contains("requestedAttachmentId") })
        XCTAssertTrue(flagged.contains { $0.contains("Duplicate Message id") })
        XCTAssertTrue(flagged.contains { $0.contains("Failed to process message") })
        // A hashed ID is not a finding, and neither is a transaction's own UUID.
        XCTAssertFalse(flagged.contains { $0.contains("Log.hashIdentifier") })
        XCTAssertFalse(flagged.contains { $0.contains("transaction.id") })
    }

    /// Every `Log.…(` and `log.…(` call in a file, each as one line: a call that spans
    /// lines is joined with single spaces, from the line that opens it to the line that
    /// closes its parentheses. The scan used to read one line at a time and only lines
    /// holding `Log.`, so a value interpolated on the line after `Log.warning(`, or any
    /// call through a `ScopedLogger` (`log.error(…)`, `self.log.…`), was never seen
    /// (architecture review 2026-11, security-privacy#4).
    ///
    /// Revert-check: `testScan_readsCallsThatSpanLines_scopedLoggers_andMessageIDs` fails
    /// if this goes back to lines, or `containsSensitiveRawLogInterpolation` to `Log.` alone.
    private static func logStatements(in contents: String) -> [String] {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var statements: [String] = []
        var index = 0
        while index < lines.count {
            guard Self.opensLogCall(lines[index]) else {
                index += 1
                continue
            }
            var parts: [String] = []
            var depth = 0
            var opened = false
            var end = index
            while end < lines.count {
                let line = lines[end]
                parts.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                for character in line {
                    if character == "(" {
                        depth += 1
                        opened = true
                    } else if character == ")" {
                        depth -= 1
                    }
                }
                if opened && depth <= 0 { break }
                end += 1
            }
            statements.append(parts.joined(separator: " "))
            index = end + 1
        }
        return statements
    }

    private static func opensLogCall(_ line: String) -> Bool {
        line.range(
            of: #"(^|[^A-Za-z0-9_.])(Log|log|self\.log)\.(debug|info|warning|error|diagnostic)\("#,
            options: .regularExpression
        ) != nil
    }

    private static func containsSensitiveRawLogInterpolation(_ line: String) -> Bool {
        guard Self.opensLogCall(line) else { return false }
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
            // A Gmail message ID under the names the persister and reconciliation give it
            // (`\(id)`, `\(message.id)`, `\(processedMessage.id)`), which the substring list
            // below misses. Not every `.id`: a transaction's or a conversation's is a UUID
            // the app made.
            if lowercasedValue == "id" || lowercasedValue.hasSuffix("message.id") {
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

    /// The raw interpolations that predate the scan, one fingerprint per call as
    /// `logStatements` renders it (a call that spans lines is joined with single spaces).
    /// Fixing one removes its entry; a stale entry fails the test, so the list cannot
    /// drift. The warning- and error-level entries left here log local file names
    /// (`FileSystemErrorHandler`, `BackupExclusion`), a blocked redirect's host and the
    /// app's own `local_` optimistic message IDs, none of them a Gmail ID or an address.
    private static let legacyRawSensitiveLogFingerprints: Set<String> = [
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to clear Core Data: \\(error)\", category: .coreData)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to clear keychain: \\(error)\", category: .auth)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to clear tokens: \\(error)\", category: .auth)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Failed to disconnect Google session during fresh install cleanup: \\(error.localizedDescription)\", category: .auth)",
        "esc-chatmail/App/FreshInstallHandler.swift|Log.warning(\"Installation ID could not be read; deferring fresh-install handling: \\(error.localizedDescription)\", category: .auth)",
        "esc-chatmail/Services/API/GmailAPIClient.swift|Log.error(\"Token refresh failed during 401 recovery: \\(error.localizedDescription)\", category: .api)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.debug(\"Download already in progress for attachment: \\(attachmentId)\", category: .attachment)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.debug(\"Retrying attachment \\(attachmentId) in \\(delay) seconds (attempt \\(attempts)/\\(maxRetryAttempts))\", category: .attachment)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.debug(\"Skipping download for local attachment: \\(attachmentId)\", category: .attachment)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.error(\"Failed to download attachment \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.error(\"Failed to save attachment updates for \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.error(\"Failed to save failed attachment state for \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.error(\"Failed to save local attachment state for \\(attachmentId)\", category: .attachment, error: error)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.warning(\"Attachment \\(attachmentId) failed after \\(maxRetryAttempts) attempts\", category: .attachment)",
        "esc-chatmail/Services/Attachments/AttachmentDownloader.swift|Log.warning(\"Failed to save original attachment file for ID: \\(attachmentId)\", category: .attachment)",
        "esc-chatmail/Services/Attachments/CIDSchemeHandler.swift|Log.debug(\"CIDSchemeHandler: Empty Content-ID from URL: \\(url)\", category: .ui)",
        "esc-chatmail/Services/Attachments/CIDSchemeHandler.swift|Log.debug(\"CIDSchemeHandler: On-demand fetch failed for attachment \\(attachmentId): \\(error.localizedDescription)\", category: .ui)",
        "esc-chatmail/Services/Caching/AttachmentCacheActor.swift|Log.debug(\"Skipping downsample for \\(attachmentId): invalid target size \\(targetSize)\", category: .attachment)",
        "esc-chatmail/Services/Caching/DiskImageCache.swift|Log.debug(\"Failed to read cache file attributes: \\(fileURL.lastPathComponent)\", category: .general)",
        "esc-chatmail/Services/Caching/RenderedMessageCache.swift|Log.diagnostic( .htmlPreview, level: .debug, \"RenderedMessageCache event=invalidated message=\\(key.messageId) sourceSignature=\\(key.sourceSignature) reason=\\(reason.rawValue)\", category: .ui )",
        "esc-chatmail/Services/Chat/FullEmailOpenSession.swift|Log.diagnostic( .htmlPreview, level: .info, \"FullEmailOpenSession loaded message \\(loadedMessageId) sourceKind=\\(source.sourceKind.rawValue) sourceLocation=\\(source.sourceLocation.rawValue) presentation=\\(source.presentation.rawValue) hasHTML=\\(source.html != nil)\", category: .ui )",
        "esc-chatmail/Services/Chat/FullEmailOpenSession.swift|Log.diagnostic(.htmlPreview, level: .info, \"FullEmailOpenSession loading message \\(loadedMessageId)\", category: .ui)",
        "esc-chatmail/Services/Chat/FullEmailReaderCoordinator.swift|Log.info(\"Opening full message for \\(message.id)\", category: .ui)",
        "esc-chatmail/Services/Chat/FullEmailWebViewManager.swift|Log.diagnostic( .htmlPreview, level: .info, \"FullEmailWebViewManager webview_checkout_hit message=\\(messageId)\", category: .ui )",
        "esc-chatmail/Services/Chat/FullEmailWebViewManager.swift|Log.diagnostic( .htmlPreview, level: .info, \"FullEmailWebViewManager webview_checkout_miss message=\\(messageId) reason=\\(reason)\", category: .ui )",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.error( \"Failed to persist delivery-unknown state for \\(optimisticMessageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.error( \"Remote send succeeded but failed to persist commit for optimistic message \\(optimisticMessageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.error( \"Remote send succeeded but local reconciliation failed for optimistic message \\(optimisticMessageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.info( \"Skipping Gmail send for already committed optimistic message \\(optimisticMessageID)\", category: .message )",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.info(\"Background send completed after cancellation for optimistic message \\(optimisticMessageID)\", category: .message)",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.info(\"Background send outcome was ambiguous for optimistic message \\(optimisticMessageID)\", category: .message)",
        "esc-chatmail/Services/Compose/ComposeSendOrchestrator.swift|Log.warning(\"Post-send sync failed - sent message will appear on next sync: \\(error.localizedDescription)\", category: .sync)",
        "esc-chatmail/Services/Contacts/ContactsResolver.swift|Log.warning(\"Contacts authorization failed for \\(operation): \\(error)\", category: .general)",
        "esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift|Log.diagnostic( .conversationRollups, \"Conversation \\(conversation.id): All participants: \\(allParticipantEmails)\", category: .conversation )",
        "esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift|Log.diagnostic( .conversationRollups, \"Excluding Hide My Email relay participant: \\(person.email)\", category: .conversation )",
        "esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift|Log.diagnostic( .conversationRollups, \"Including unresolved participant placeholder for: \\(email)\", category: .conversation )",
        "esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift|Log.diagnostic( .conversationRollups, \"My email: \\(myEmail) (normalized: \\(normalizedMyEmail))\", category: .conversation )",
        "esc-chatmail/Services/Conversation/ConversationRollupUpdater.swift|Log.diagnostic(.conversationRollups, \"Excluding self: \\(email)\", category: .conversation)",
        "esc-chatmail/Services/CoreData/CoreDataBackupManager.swift|Log.warning(\"Failed to remove old backup: \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift|Log.info(\"Created backup before store reset: \\(backupURL.path)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataRecoveryHandler.swift|Log.warning(\"Core Data load attempt \\(currentAttempts) failed with recoverable error: \\(error)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataSaveOperations.swift|Log.debug(\"  - Detail: \\(detailedError.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/CoreData/CoreDataSaveOperations.swift|Log.error(\"Core Data save error in \\(caller): \\(error.localizedDescription)\", category: .coreData)",
        "esc-chatmail/Services/EmailDOM/ParsedEmail.swift|Log.diagnostic( .htmlPreview, level: .debug, \"ParsedEmailProvider event=parse-failure message=\\(key.messageId) sourceSignature=\\(key.sourceSignature) duration=\\(String(format: \"%.3f\", duration))s failures=\\(parseFailureCount)\", category: .ui )",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.debug(\"Failed to get file size for \\(url.lastPathComponent)\", category: category)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.debug(\"Failed to list contents of \\(url.lastPathComponent)\", category: category)",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.warning( \"Failed to copy \\(sourceURL.lastPathComponent) to \\(destinationURL.lastPathComponent)\", category: category )",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.warning( \"Failed to create directory at \\(url.lastPathComponent)\", category: category )",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.warning( \"Failed to load data from \\(url.lastPathComponent)\", category: category )",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.warning( \"Failed to move \\(sourceURL.lastPathComponent) to \\(destinationURL.lastPathComponent)\", category: category )",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.warning( \"Failed to remove item at \\(url.lastPathComponent)\", category: category )",
        "esc-chatmail/Services/ErrorHandling/FileSystemErrorHandler.swift|Log.warning( \"Failed to write data to \\(url.lastPathComponent)\", category: category )",
        "esc-chatmail/Services/HTMLContent/CanonicalEmailContentLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"CanonicalEmailContentLoader message \\(messageId): no canonical content\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/CanonicalEmailContentLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"CanonicalEmailContentLoader message \\(messageId): sourceKind=\\(content.sourceKind.rawValue) sourceLocation=\\(content.sourceLocation.rawValue) hasHTML=\\(content.hasHTMLSource)\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift|Log.debug(\"Failed to read creation date for \\(fileURL.lastPathComponent)\", category: .general)",
        "esc-chatmail/Services/HTMLContent/HTMLContentHandler.swift|Log.error(\"Failed to load HTML from \\(url)\", category: .general, error: error)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader+SourcePreparation.swift|Log.debug( \"Warmed attachment-style remote image fallback for message \\(messageId)\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader+SourcePreparation.swift|Log.debug( \"wrappedHTMLIfMeaningful: original quality fallback for \\(messageId): \\(evaluation.summary)\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: original preferHTML content not meaningful for \\(messageId) (len=\\(safeHTML.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: sanitized HTML not meaningful for \\(messageId) (len=\\(sanitizedHTML.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: wrapped HTML not meaningful for \\(messageId) (len=\\(wrapped.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader+SourcePreparation.swift|Log.debug(\"wrappedHTMLIfMeaningful: wrapped original preferHTML not meaningful for \\(messageId) (len=\\(wrapped.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader.swift|Log.debug(\"loadContent: All HTML methods failed for \\(messageId), falling back to plain text (bodyText=\\(bodyText?.count ?? 0) chars)\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader.swift|Log.debug(\"loadContent: Method 1 (messageId file) rejected by wrappedHTMLIfMeaningful for \\(messageId) (htmlLen=\\(html.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader.swift|Log.debug(\"loadContent: Method 2 (storageURI) rejected by wrappedHTMLIfMeaningful for \\(messageId) (htmlLen=\\(html.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentLoader.swift|Log.debug(\"loadContent: Method 3 (rawSourceHTML) rejected by wrappedHTMLIfMeaningful for \\(messageId) (htmlLen=\\(html.count))\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentRecoveryService.swift|Log.debug(\"No HTML body found for message \\(messageId)\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentRecoveryService.swift|Log.info(\"Recovered HTML content for message \\(messageId)\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentRecoveryService.swift|Log.warning(\"Failed to fetch large body \\(attachmentId) for message \\(messageId): \\(error)\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentRecoveryService.swift|Log.warning(\"Failed to recover HTML for \\(messageId): \\(errorCode)\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/HTMLContentRecoveryService.swift|Log.warning(\"Recovery for message \\(messageId) timed out after \\(Int(recoveryNetworkTimeout.rounded()))s\", category: .ui)",
        "esc-chatmail/Services/HTMLContent/OriginalEmailSourceLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"OriginalEmailSourceLoader message \\(messageId): HTML source existed but could not be prepared; not falling back to plain text\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/OriginalEmailSourceLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"OriginalEmailSourceLoader message \\(messageId): HTML source existed but could not be prepared; using plain text fallback\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/OriginalEmailSourceLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"OriginalEmailSourceLoader message \\(messageId): no source\", category: .ui )",
        "esc-chatmail/Services/HTMLContent/OriginalEmailSourceLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"OriginalEmailSourceLoader message \\(messageId): sourceKind=\\(source.sourceKind.rawValue) sourceLocation=\\(source.sourceLocation.rawValue) presentation=\\(source.presentation.rawValue)\", category: .ui )",
        "esc-chatmail/Services/PendingActions/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed archive for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed markRead for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed markUnread for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed star for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/ActionExecutor.swift|Log.diagnostic(.pendingActions, \"Executed unstar for message: \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/PendingActionProcessor.swift|Log.diagnostic( .pendingActions, level: .info, \"Processed action: \\(type.rawValue) for message: \\(messageId ?? \"N/A\")\", category: .sync )",
        "esc-chatmail/Services/PendingActions/PendingActionProcessor.swift|Log.error(\"Failed to process action: \\(error)\", category: .sync)",
        "esc-chatmail/Services/PendingActions/PendingActionQueries.swift|Log.error(\"Failed to cancel pending action for message \\(messageId)\", category: .sync, error: error)",
        "esc-chatmail/Services/PendingActions/PendingActionsManager.swift|Log.error(\"Failed to save pending action \\(type.rawValue) for message \\(messageId) - action will not be queued\", category: .sync)",
        "esc-chatmail/Services/Preview/EmailPreviewPipeline.swift|Log.diagnostic( .htmlPreview, level: .info, \"EmailPreviewPipeline message \\(request.messageId): no HTML preview source\", category: .ui )",
        "esc-chatmail/Services/Preview/EmailPreviewPipeline.swift|Log.diagnostic( .htmlPreview, level: .info, \"EmailPreviewPipeline message \\(request.messageId): sourceKind=\\(previewSource.sourceKind.rawValue) \\(classification.diagnosticSummary)\", category: .ui )",
        "esc-chatmail/Services/Preview/EmailPreviewPipeline.swift|Log.diagnostic( .htmlPreview, level: .info, \"EmailPreviewPipeline message \\(request.messageId): using fallback preview source=\\(fallback.source)\", category: .ui )",
        "esc-chatmail/Services/Preview/EmailPreviewPipeline.swift|Log.diagnostic( .htmlPreview, level: .info, \"EmailPreviewPipeline newsletter fallback for message \\(request.messageId): preview model unavailable\", category: .ui )",
        "esc-chatmail/Services/Preview/EmailPreviewPipeline.swift|Log.diagnostic( .htmlPreview, level: .info, \"EmailPreviewPipeline transactional fallback for message \\(request.messageId): preview model unavailable\", category: .ui )",
        "esc-chatmail/Services/Preview/EmailPreviewSourceLoader.swift|Log.diagnostic( .htmlPreview, level: .info, \"EmailPreviewSourceLoader message \\(messageId): sourceKind=\\(canonicalContent.sourceKind.rawValue) sourceLocation=\\(canonicalContent.sourceLocation.rawValue)\", category: .ui )",
        "esc-chatmail/Services/Security/AuthSession.swift|Log.warning(\"Failed to restore previous sign-in: \\(error.localizedDescription)\", category: .auth)",
        "esc-chatmail/Services/Security/SSRFGuardingURLSession.swift|Log.warning( \"SSRFGuardingURLSession blocked redirect to private host \\(url.host ?? \"<nil>\")\", category: .general )",
        "esc-chatmail/Services/Security/TokenManager+Refresh.swift|Log.warning(\"Token refresh attempt \\(attempt + 1) failed: \\(error)\", category: .auth)",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.error( \"Failed to preserve cold in-flight send as delivery-unknown \\(snapshot.optimisticMessageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.error( \"Failed to preserve legacy optimistic send as delivery-unknown \\(snapshot.optimisticMessageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.error( \"Failed to reconcile remote committed optimistic send \\(snapshot.optimisticMessageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.error( \"Failed to retain definitely unsent optimistic message \\(messageID)\", category: .message, error: error )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.info( \"Remote send mutation already consumed before API success for \\(optimisticMessageID)\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.info( \"Retaining remote committed anchored send \\(optimisticMessageID) for sync routing\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.info( \"Retaining remote committed list send \\(optimisticMessageID) until a reusable list conversation resolves\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.info( \"Retaining remote committed send \\(optimisticMessageID) until its existing conversation route resolves\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.warning( \"Remote committed send \\(optimisticMessageID) has no local optimistic message; clearing mutation record and relying on sync\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.warning( \"Retaining ambiguous optimistic send \\(snapshot.optimisticMessageID) to avoid a duplicate retry\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.warning( \"Retaining interrupted in-flight send \\(snapshot.optimisticMessageID) to avoid a duplicate retry\", category: .message )",
        "esc-chatmail/Services/Send/GmailSendService+OptimisticUpdates.swift|Log.warning( \"Retaining legacy optimistic send \\(snapshot.optimisticMessageID) as delivery-unknown to avoid a duplicate retry\", category: .message )",
        "esc-chatmail/Services/Sync/HistoryProcessor.swift|Log.debug( \"Skipping \\(excludedMailboxLabel.lowercased()): \\(added.message.id)\", category: .sync )",
        "esc-chatmail/Services/Sync/HistoryProcessor.swift|Log.debug(\"Will fetch: \\(added.message.id)\", category: .sync)",
        "esc-chatmail/Services/Sync/IncrementalSyncOrchestrator.swift|Log.warning(\"Failed to refresh send-as aliases; using cached aliases: \\(error.localizedDescription)\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Found local message \\(messageId), applying label removal\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Message \\(messageId) not found locally - skipping\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Removed label '\\(labelId)' from message \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.debug(\"Skipping server label \\(operation) for message \\(messageId) - local changes pending\", category: .sync)",
        "esc-chatmail/Services/Sync/LabelOperationProcessor.swift|Log.warning(\"Only found \\(foundLabels) of \\(labelIds.count) labels for message \\(messageId)\", category: .sync)",
        "esc-chatmail/Services/Sync/MessagePersister.swift|Log.debug(\"Skipping \\(label.lowercased()) message: \\(id)\", category: .sync)",
        "esc-chatmail/Services/Sync/MessagePersister.swift|Log.error(\"Failed to create message \\(processedMessage.id): \\(error)\", category: .sync)",
        "esc-chatmail/Services/Sync/MessageProcessor.swift|Log.debug(\"Skipping embedded-HTML probe for message \\(messageId): \\(error)\", category: .sync)",
        "esc-chatmail/Services/Sync/MessageProcessor.swift|Log.warning(\"Failed to fetch large body \\(attachmentId) for message \\(messageId): \\(error)\", category: .sync)",
        "esc-chatmail/Services/Sync/MessageProcessor.swift|Log.warning(\"Large body \\(attachmentId) for message \\(messageId) gone server-side (404); persisting without it\", category: .sync)",
        "esc-chatmail/Services/Sync/MessageProcessor.swift|Log.warning(\"Large body \\(attachmentId) for message \\(messageId) undecodable (deterministic); persisting without it: \\(error)\", category: .sync)",
        "esc-chatmail/Services/Sync/Persistence/MessagePersister+Participants.swift|Log.error(\"Failed to create participant for message \\(message.id): \\(error)\", category: .coreData)",
        "esc-chatmail/Services/Sync/Persistence/MessagePersister+Updates.swift|Log.debug( \"Preserving local mailbox state for message \\(processedMessage.id) while pending action exists\", category: .sync )",
        "esc-chatmail/Services/Sync/Persistence/MessagePersister+Updates.swift|Log.debug( \"Preserving local outgoing body text for message \\(processedMessage.id) over snippet-only sync body\", category: .sync )",
        "esc-chatmail/Services/Sync/Persistence/MessagePersister+Updates.swift|Log.debug(\"Updated existing message: \\(processedMessage.id)\", category: .sync)",
        "esc-chatmail/Services/Sync/SyncFailureTracker.swift|Log.warning(\"Giving up on abandoned message \\(record.gmailMessageId) after \\(retryCount) retries\", category: .sync)",
        "esc-chatmail/Services/Sync/SyncReconciliation.swift|log.debug(\"Label reconciliation: no mismatches (checked \\(recentMessageIds.count - stats.notInLocalDB) local messages)\")",
        "esc-chatmail/Services/Sync/SyncReconciliation.swift|log.debug(\"Message \\(messageId) was deleted from Gmail, skipping reconciliation\")",
        "esc-chatmail/Services/TextProcessing/EmailTextProcessor.swift|Log.debug(\"Failed to create attributed string from HTML: \\(error)\", category: .message)",
        "esc-chatmail/Services/Utilities/BackupExclusion.swift|Log.warning( \"Could not \\(excluded ? \"exclude\" : \"include\") \\(url.lastPathComponent) \\(excluded ? \"from\" : \"in\") backups\", category: category )",
        "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|Log.debug(\"WebView navigation failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|Log.debug(\"WebView preview height measurement failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|Log.debug(\"WebView provisional navigation failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/EmailContentSection.swift|Log.diagnostic(.htmlPreview, \"EmailContentSection: No HTML content for message \\(message.id)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/FullEmailReaderWebView.swift|Log.debug(\"WebView navigation failed: \\(error)\", category: .ui)",
        "esc-chatmail/Views/Components/EmailContent/FullEmailReaderWebView.swift|Log.debug(\"WebView provisional navigation failed: \\(error)\", category: .ui)",
    ]
}
