import XCTest
@testable import esc_chatmail

/// What is left out of device backups, and that it still is after each way a marked directory
/// or file can be made again (scalability review step 7, `no-backup-exclusion`).
///
/// The mark is the file's or the directory's own, so it is lost wherever one is made again:
/// a directory removed at sign-out and created at the next sign-in, a file rewritten
/// atomically. Each such place marks again, and each has a test here that fails without it.
final class BackupExclusionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupExclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - The mark itself

    func testExcludeAndInclude_setAndClearTheMark() throws {
        let file = directory.appendingPathComponent("file.bin")
        try Data("x".utf8).write(to: file)

        XCTAssertFalse(BackupExclusion.isExcluded(file))
        XCTAssertTrue(BackupExclusion.exclude(file))
        XCTAssertTrue(BackupExclusion.isExcluded(file))
        XCTAssertTrue(BackupExclusion.include(file))
        XCTAssertFalse(BackupExclusion.isExcluded(file))
    }

    func testExclude_ofAMissingItem_reportsFailure() {
        XCTAssertFalse(BackupExclusion.exclude(directory.appendingPathComponent("missing")))
    }

    /// The three behaviours the call sites are written around. If the system changes one,
    /// this says so before a backup does.
    func testTheMark_travelsWithACopyAndARename_andIsLostByAnAtomicRewrite() throws {
        let file = directory.appendingPathComponent("original.bin")
        try Data("x".utf8).write(to: file, options: .atomic)
        XCTAssertTrue(BackupExclusion.exclude(file))

        let copy = directory.appendingPathComponent("copy.bin")
        try FileManager.default.copyItem(at: file, to: copy)
        XCTAssertTrue(BackupExclusion.isExcluded(copy), "A copy carries the mark, so a copy handed to the user must have it taken off")

        let renamed = directory.appendingPathComponent("renamed.bin")
        try FileManager.default.moveItem(at: copy, to: renamed)
        XCTAssertTrue(BackupExclusion.isExcluded(renamed))

        try Data("y".utf8).write(to: file, options: .atomic)
        XCTAssertFalse(BackupExclusion.isExcluded(file), "An atomic write makes a new file, so a download is marked after each write")
    }

    // Revert-check: `guard marksFiles() else { return false }` opening
    // `BackupExclusion.setExcluded`, and the `SandboxTripwirePolicy` verdict in `marksFiles`.
    // HONEST SCOPE: source text for the macOS branch, which the iOS test target does not
    // compile; an unsandboxed Mac build must never be launched, so no test runs it either.
    // What runs here is the iOS answer.
    func testNothingIsMarkedOutsideTheAppSandboxOnTheMac() throws {
        #if os(iOS)
        XCTAssertTrue(BackupExclusion.marksFiles(environment: [:]), "Every iOS app is sandboxed")
        #endif

        let code = try repositorySource("esc-chatmail/Services/Utilities/BackupExclusion.swift")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        let write = try XCTUnwrap(code.firstIndex {
            $0.hasPrefix("private static func setExcluded(")
        })
        XCTAssertEqual(
            code[write + 1],
            "guard marksFiles() else { return false }",
            "The one function that writes the mark must ask first"
        )
        XCTAssertEqual(
            code.filter { $0.contains("setResourceValues(") }.count,
            1,
            "The mark is written in one place"
        )
        let question = try XCTUnwrap(code.firstIndex { $0.hasPrefix("static func marksFiles(") })
        XCTAssertEqual(
            Array(code[(question + 3)...(question + 5)]),
            [
                "#if os(macOS)",
                "return SandboxTripwirePolicy.destructiveCleanupVerdict(environment: environment) == .permitted",
                "#else"
            ]
        )
    }

    // MARK: - Messages

    // Revert-check: `excludeMessagesDirectoryFromBackup()` in
    // `HTMLContentHandler.createMessagesDirectoryIfNeeded`, for a directory it creates and,
    // outside the `if`, for one it finds: an installation from before the mark has the
    // directory already.
    func testMessagesDirectory_isLeftOutOfBackups_whetherTheHandlerMadeItOrFoundIt() throws {
        let made = directory.appendingPathComponent("Made", isDirectory: true)
        _ = HTMLContentHandler(messagesDirectory: made)
        XCTAssertTrue(BackupExclusion.isExcluded(made))

        let found = directory.appendingPathComponent("Found", isDirectory: true)
        try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
        XCTAssertFalse(BackupExclusion.isExcluded(found))
        _ = HTMLContentHandler(messagesDirectory: found)
        XCTAssertTrue(BackupExclusion.isExcluded(found))
    }

    // Revert-check: `excludeMessagesDirectoryFromBackup()` in
    // `HTMLContentHandler.reopenAccountWork`. A sign-out takes the directory away, the
    // reopen makes a new one, and without the call the next account's bodies are backed up.
    func testMessagesDirectory_madeAgainAfterASignOut_isLeftOutOfBackups() async throws {
        let messages = directory.appendingPathComponent("Messages", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: messages)
        defer { try? handler.reopenAccountWork() }
        XCTAssertNotNil(handler.saveHTML("<p>old account</p>", for: "old"))

        handler.closeAccountWork()
        try await handler.deleteAllHTMLFromClosedAccount()
        // However the cleanup leaves the directory, the reopen below starts from none.
        try? FileManager.default.removeItem(at: messages)
        XCTAssertFalse(FileManager.default.fileExists(atPath: messages.path))
        try handler.reopenAccountWork()

        XCTAssertTrue(BackupExclusion.isExcluded(messages))
        XCTAssertFalse(handler.htmlFileExists(for: "old"))
    }

    // Revert-check: `excludeMessagesDirectoryFromBackup()` in the recreate branch of
    // `HTMLContentHandler.saveHTMLResult`.
    func testMessagesDirectory_madeAgainByASave_isLeftOutOfBackups() throws {
        let messages = directory.appendingPathComponent("Messages", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: messages)
        try FileManager.default.removeItem(at: messages)

        XCTAssertNotNil(handler.saveHTML("<p>body</p>", for: "message"))

        XCTAssertTrue(BackupExclusion.isExcluded(messages))
    }

    // MARK: - Attachments and previews

    // Revert-check: `BackupExclusion.exclude(previewsURL)` in `AttachmentPaths.setupDirectories`.
    // The mark is taken off the test host's own Previews directory first, which is what a
    // directory made again after a sign-out, or one from an earlier build, looks like.
    func testSetupDirectories_leavesPreviewsOutOfBackups_andNotAttachments() throws {
        AttachmentPaths.setupDirectories()
        let previews = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.previewsFolder))
        let attachments = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.attachmentsFolder))
        XCTAssertTrue(BackupExclusion.include(previews))

        AttachmentPaths.setupDirectories()

        XCTAssertTrue(BackupExclusion.isExcluded(previews))
        XCTAssertFalse(
            BackupExclusion.isExcluded(attachments),
            "Attachments also holds originals the user added, which cannot be downloaded again"
        )
    }

    // Revert-check: the `isRedownloadable` branch of `AttachmentPaths.saveData`, and that it
    // comes after the write: the second save here is a new file.
    func testSaveData_marksADownloadedAttachmentAfterEveryWrite_andNeverAUsersOriginal() throws {
        AttachmentPaths.setupDirectories()
        let downloadedPath = AttachmentPaths.originalPath(
            messageId: "backup-\(UUID().uuidString)",
            attachmentId: "att-1",
            ext: "bin"
        )
        let originalPath = AttachmentPaths.originalPath(idOrUUID: "local_\(UUID().uuidString)", ext: "bin")
        defer {
            AttachmentPaths.deleteFile(at: downloadedPath)
            AttachmentPaths.deleteFile(at: originalPath)
        }
        let downloaded = try XCTUnwrap(AttachmentPaths.fullURL(for: downloadedPath))
        let original = try XCTUnwrap(AttachmentPaths.fullURL(for: originalPath))

        XCTAssertTrue(AttachmentPaths.saveData(Data("first".utf8), to: downloadedPath))
        XCTAssertTrue(BackupExclusion.isExcluded(downloaded))
        XCTAssertTrue(AttachmentPaths.saveData(Data("downloaded again".utf8), to: downloadedPath))
        XCTAssertTrue(BackupExclusion.isExcluded(downloaded))

        XCTAssertTrue(AttachmentPaths.saveData(Data("mine".utf8), to: originalPath))
        XCTAssertFalse(BackupExclusion.isExcluded(original))
    }

    func testIsRedownloadable_isTrueOnlyForAFileStoredUnderAMessageAndAttachmentID() {
        XCTAssertTrue(
            AttachmentPaths.isRedownloadable(
                AttachmentPaths.originalPath(messageId: "m", attachmentId: "a", ext: "pdf")
            )
        )
        XCTAssertFalse(AttachmentPaths.isRedownloadable(AttachmentPaths.originalPath(idOrUUID: "local_1", ext: "pdf")))
        // A legacy ID-only path of a Gmail attachment: not provably a download by its name.
        XCTAssertFalse(AttachmentPaths.isRedownloadable(AttachmentPaths.originalPath(idOrUUID: "ANGjdJ8w", ext: "pdf")))
        // A preview is covered by its directory, not one by one.
        XCTAssertFalse(AttachmentPaths.isRedownloadable(AttachmentPaths.previewPath(messageId: "m", attachmentId: "a")))
    }

    // MARK: - Quick Look

    // Revert-check: `QuickLookBackupMark.handOver`, and the `applyBackupPolicy` in
    // `QuickLookBackupMark.takeBack`. Without the first the downloaded file keeps its mark
    // while Quick Look's share button can copy it; without the second it is left in backups
    // after Quick Look closes, until the daily orphan sweep.
    func testQuickLook_takesTheMarkOffWhatItShows_andPutsItBackByTheFilesName() throws {
        AttachmentPaths.setupDirectories()
        let downloadedPath = AttachmentPaths.originalPath(
            messageId: "quick-look-\(UUID().uuidString)",
            attachmentId: "att-1",
            ext: "pdf"
        )
        let originalPath = AttachmentPaths.originalPath(idOrUUID: "local_\(UUID().uuidString)", ext: "jpg")
        defer {
            AttachmentPaths.deleteFile(at: downloadedPath)
            AttachmentPaths.deleteFile(at: originalPath)
        }
        XCTAssertTrue(AttachmentPaths.saveData(Data("downloaded".utf8), to: downloadedPath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("mine".utf8), to: originalPath))
        let downloaded = try XCTUnwrap(AttachmentPaths.fullURL(for: downloadedPath))
        let original = try XCTUnwrap(AttachmentPaths.fullURL(for: originalPath))
        XCTAssertTrue(BackupExclusion.isExcluded(downloaded), "Precondition: a download is marked when written")

        QuickLookBackupMark.handOver([downloaded, original])

        XCTAssertFalse(BackupExclusion.isExcluded(downloaded), "What Quick Look shares must carry no mark")
        XCTAssertFalse(BackupExclusion.isExcluded(original))

        QuickLookBackupMark.takeBack([downloaded, original])

        XCTAssertTrue(BackupExclusion.isExcluded(downloaded))
        XCTAssertFalse(BackupExclusion.isExcluded(original), "A user's original is never marked")
    }

    // The Mac's Quick Look is SwiftUI's panel, which no test mounts: its hand-over is pinned
    // from the modifier's source.
    // Revert-check: either `QuickLookBackupMark` call on `handedOverURLs` in the Mac branch of
    // `AttachmentQuickLookModifier`.
    // HONEST SCOPE: this reads source text. It proves the calls are there, not that SwiftUI
    // calls the closures they are in when the panel opens and closes.
    func testMacQuickLookPanel_handsOverAndTakesBackTheFilesItWasGiven() throws {
        let source = try repositorySource("esc-chatmail/Platform/AttachmentQuickLookModifier.swift")

        XCTAssertTrue(source.contains("QuickLookBackupMark.handOver(handedOverURLs)"))
        XCTAssertTrue(source.contains("QuickLookBackupMark.takeBack(handedOverURLs)"))
    }

    // MARK: - Avatars

    // Revert-check: `BackupExclusion.exclude(directory)` in
    // `AvatarStorage.createDirectoryIfNeeded`, which both the initializer and
    // `deleteAllAvatars` end in. Without it the directory has no mark, neither when it is
    // found nor when it is made again.
    func testAvatarsDirectory_isLeftOutOfBackups_whenFound_andAfterEveryAvatarIsDeleted() async throws {
        let avatars = directory.appendingPathComponent("Avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)

        let storage = AvatarStorage(avatarsDirectory: avatars)
        XCTAssertTrue(BackupExclusion.isExcluded(avatars))

        _ = await storage.saveAvatar(for: "someone@example.com", imageData: Data([1, 2, 3]))
        await storage.deleteAllAvatars()

        XCTAssertTrue(FileManager.default.fileExists(atPath: avatars.path))
        XCTAssertTrue(BackupExclusion.isExcluded(avatars))
        let exists = await storage.avatarExists(for: "someone@example.com")
        XCTAssertFalse(exists)
    }
}
