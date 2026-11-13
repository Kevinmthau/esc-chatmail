import XCTest
@testable import esc_chatmail

/// The copy of an attachment another app is given to open (`AttachmentOpenCopy`), in a
/// temporary directory: it runs in the Mac plan too, where the test host's container is the
/// real one.
final class AttachmentOpenCopyTests: XCTestCase {
    private var directory: URL!
    private var sources: URL!
    private var opened: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentOpenCopyTests-\(UUID().uuidString)", isDirectory: true)
        sources = directory.appendingPathComponent("sources", isDirectory: true)
        opened = directory.appendingPathComponent("Opened", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func item(stored: String, filename: String, bytes: String) throws -> AttachmentExportItem {
        let url = sources.appendingPathComponent(stored)
        try Data(bytes.utf8).write(to: url)
        return AttachmentExportItem(sourceURL: url, filename: filename)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    /// Revert-check: returning `item.sourceURL` from `AttachmentOpenCopy.prepare` makes this
    /// fail: the other app would be handed the app's own file, under its storage name.
    func testPrepare_copiesTheFileUnderTheAttachmentsName_inAFolderForThatAttachment() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Q3 report.pdf", bytes: "report bytes")

        let copy = try AttachmentOpenCopy.prepare(item, in: opened)

        XCTAssertEqual(copy, opened.appendingPathComponent("remote_abc.pdf/Q3 report.pdf"))
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "report bytes")
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "report bytes")
    }

    /// Preview saves a markup into the file it has open. A read-only file it shows as locked.
    ///
    /// Revert-check: deleting the `setAttributes` call from `AttachmentOpenCopy.prepare` makes
    /// this fail.
    func testPrepare_theCopyIsReadOnly_andTheAttachmentsOwnFileIsLeftAsItWas() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        let sourcePermissions = try permissions(of: item.sourceURL)

        let copy = try AttachmentOpenCopy.prepare(item, in: opened)

        XCTAssertEqual(try permissions(of: copy), 0o444)
        XCTAssertEqual(try permissions(of: item.sourceURL), sourcePermissions)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: copy.path))
    }

    /// Sign-out removes the `Attachments` directory with one call, and it must not fail: a
    /// file locked with the user-immutable flag makes that call fail, which is why the copy
    /// is read-only by permission instead.
    ///
    /// HONEST SCOPE: the copy was never locked, so there is no line to revert. The test
    /// after this one shows what a locked file does to the same call.
    func testPrepare_theFolderOfCopiesCanStillBeRemovedWhole() throws {
        _ = try AttachmentOpenCopy.prepare(
            try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes"),
            in: opened
        )

        XCTAssertNoThrow(try FileManager.default.removeItem(at: opened))
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
    }

    /// The reason the copy is read-only by permission: a folder with a locked file in it
    /// cannot be removed, and a folder with a read-only file in it can.
    func testALockedFile_stopsItsFolderBeingRemoved_whichIsWhyTheCopyIsNotLocked() throws {
        let folder = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = folder.appendingPathComponent("Report.pdf")
        try Data("bytes".utf8).write(to: file)
        var lock = URLResourceValues()
        lock.isUserImmutable = true
        do {
            try file.setResourceValues(lock)
        } catch {
            throw XCTSkip("This volume does not take the user-immutable flag: \(error)")
        }
        defer {
            // Unlocked whatever the assertions find, or the test's directory cannot be
            // removed either.
            var unlock = URLResourceValues()
            unlock.isUserImmutable = false
            try? file.setResourceValues(unlock)
        }

        XCTAssertThrowsError(try FileManager.default.removeItem(at: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Revert-check: deleting the `if isCurrent(...)` return from `AttachmentOpenCopy.prepare`
    /// makes this fail: every Open would copy the file again.
    func testPrepare_openedAgain_usesTheCopyItMade() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        let first = try AttachmentOpenCopy.prepare(item, in: opened)
        let firstIdentity = try FileManager.default.attributesOfItem(atPath: first.path)[.systemFileNumber] as? NSNumber

        let second = try AttachmentOpenCopy.prepare(item, in: opened)

        XCTAssertEqual(second, first)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: second.path)[.systemFileNumber] as? NSNumber,
            firstIdentity
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: opened.path), ["remote_abc.pdf"])
    }

    /// The orphan sweep removes the folder of copies once its own dates are older than the
    /// sweep's grace period. A copy handed out again adds nothing to the folder, so the date
    /// is moved for it.
    ///
    /// Revert-check: deleting the `markInUse` call from the `if isCurrent(...)` branch of
    /// `AttachmentOpenCopy.prepare` makes this fail: two hours on, the folder the copy was
    /// just handed out of is still one the sweep removes.
    func testPrepare_openedAgain_marksTheFolderOfCopiesAsUsed_soTheSweepLeavesIt() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        let firstOpen = Date()
        _ = try AttachmentOpenCopy.prepare(item, in: opened, now: firstOpen)
        let twoHoursOn = firstOpen.addingTimeInterval(2 * 60 * 60)
        let sweepCutoff = twoHoursOn.addingTimeInterval(-AttachmentDownloader.orphanSweepRecentFileGracePeriod)
        // A new URL for each look, as the sweep has from its own directory listing: a URL
        // keeps the dates it was first asked for, and `opened` asked twice answered the
        // second time with the first one's.
        let folderAsTheSweepSeesIt = { URL(fileURLWithPath: self.opened.path) }
        // Left alone, the folder is one a sweep two hours on removes.
        XCTAssertTrue(AttachmentDownloader.isOldEnoughToSweep(folderAsTheSweepSeesIt(), cutoff: sweepCutoff))

        _ = try AttachmentOpenCopy.prepare(item, in: opened, now: twoHoursOn)

        XCTAssertFalse(AttachmentDownloader.isOldEnoughToSweep(folderAsTheSweepSeesIt(), cutoff: sweepCutoff))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: opened.path), ["remote_abc.pdf"])
    }

    /// Revert-check: deleting the `markInUse` call after `setAttributes` in
    /// `AttachmentOpenCopy.prepare` makes this fail.
    ///
    /// HONEST SCOPE: in the app a new copy's folder moves the date by being added, at the
    /// time it is added. This pins that the date is the one `prepare` was given.
    func testPrepare_aNewCopy_marksTheFolderOfCopiesAsUsedAtTheGivenTime() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        let given = Date().addingTimeInterval(3 * 60 * 60)

        _ = try AttachmentOpenCopy.prepare(item, in: opened, now: given)

        let modified = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: opened.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(modified.timeIntervalSince(given), 0, accuracy: 1)
    }

    /// A copy cut short by a quit is not the attachment.
    ///
    /// Revert-check: answering true from `AttachmentOpenCopy.isCurrent` for any file that
    /// exists makes this fail.
    func testPrepare_aCopyOfAnotherLength_isReplaced() throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "the whole file")
        let folder = opened.appendingPathComponent("remote_abc.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("Report.pdf")
        try Data("the wh".utf8).write(to: partial)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: partial.path)

        let copy = try AttachmentOpenCopy.prepare(item, in: opened)

        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "the whole file")
        XCTAssertEqual(try permissions(of: copy), 0o444)
    }

    /// Photos from a phone are often all named alike.
    ///
    /// Revert-check: naming the folder for `item.filename` in `AttachmentOpenCopy.folderName`
    /// makes this fail: the second attachment would open the first one's copy.
    func testPrepare_twoAttachmentsWithOneName_haveACopyEach() throws {
        let first = try item(stored: "remote_1.jpg", filename: "image.jpg", bytes: "first")
        let second = try item(stored: "remote_2.jpg", filename: "image.jpg", bytes: "other")

        let firstCopy = try AttachmentOpenCopy.prepare(first, in: opened)
        let secondCopy = try AttachmentOpenCopy.prepare(second, in: opened)

        XCTAssertNotEqual(firstCopy, secondCopy)
        XCTAssertEqual(try String(contentsOf: firstCopy, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: secondCopy, encoding: .utf8), "other")
    }

    /// Revert-check: deleting the `guard fileManager.fileExists(atPath: item.sourceURL.path)`
    /// from `AttachmentOpenCopy.prepare` makes this fail: the error is the system's copy
    /// error, with the wrong words for the user.
    func testPrepare_whenTheAttachmentsFileIsGone_saysSo_andMakesNothing() {
        let item = AttachmentExportItem(
            sourceURL: sources.appendingPathComponent("gone.pdf"),
            filename: "Report.pdf"
        )

        XCTAssertThrowsError(try AttachmentOpenCopy.prepare(item, in: opened)) { error in
            XCTAssertEqual(error as? AttachmentFileExport.ExportError, .sourceMissing(filename: "Report.pdf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
    }

    /// The copies are account data. Under `Attachments` they are removed by sign-out and by
    /// a fresh install, counted by the check for another account's files, and swept when old;
    /// in the temporary directory none of those would know of them.
    ///
    /// Revert-check: building `AttachmentOpenCopy.defaultDirectory` from
    /// `FileManager.default.temporaryDirectory` makes this fail.
    func testDefaultDirectory_isInsideTheAttachmentsFolder() throws {
        let directory = try XCTUnwrap(AttachmentOpenCopy.defaultDirectory())
        let attachments = try XCTUnwrap(AttachmentPaths.fullURL(for: AttachmentPaths.attachmentsFolder))

        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL, attachments.standardizedFileURL)
        XCTAssertEqual(directory.lastPathComponent, "Opened")
    }
}
