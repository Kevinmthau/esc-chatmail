import XCTest
@testable import esc_chatmail

/// A cleanup takes a directory of account files out of use in one rename and leaves the
/// unlinks to a background task (`RetiredAccountDirectory`; scalability review step 7,
/// `signout-o-n-file-deletion`).
///
/// HONEST SCOPE: nothing here measures time. What is asserted is the structure that makes
/// the critical path independent of the number of files: after the call that a sign-out
/// awaits has returned, every file is still on disk, under the tombstone, and nothing has
/// been unlinked.
final class RetiredAccountDirectoryTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("RetiredAccountDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        restoreWritePermissions(under: root)
        try? fileManager.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Taking a directory out of use

    // Revert-check: the `moveItem` in `RetiredAccountDirectory.takeOutOfUse`. Remove the
    // directory's files there instead, as the cleanup did before, and no tombstone holds
    // them: the file-number assertion fails, and so does the count.
    func testTakeOutOfUse_renamesTheDirectory_andUnlinksNothing() throws {
        let messages = try makeDirectory("Messages", files: ["a.html", "b.html", "c.html"])
        let fileNumberBefore = try fileNumber(of: messages.appendingPathComponent("a.html"))

        let tombstone = try XCTUnwrap(RetiredAccountDirectory.takeOutOfUse(messages))

        XCTAssertFalse(fileManager.fileExists(atPath: messages.path), "The live directory is out of use at once")
        XCTAssertTrue(RetiredAccountDirectory.isTombstone(tombstone))
        XCTAssertEqual(tombstone.deletingLastPathComponent().path, root.path, "A sibling, so the same volume")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: tombstone.path).sorted(), ["a.html", "b.html", "c.html"])
        XCTAssertEqual(
            try fileNumber(of: tombstone.appendingPathComponent("a.html")),
            fileNumberBefore,
            "The same file under another name: it was renamed, not copied and not removed"
        )
        XCTAssertEqual(RetiredAccountDirectory.tombstones(of: messages).map(\.path), [tombstone.path])
        XCTAssertTrue(
            BackupExclusion.isExcluded(tombstone),
            "A tombstone waiting to be removed is not worth a backup"
        )
    }

    func testTakeOutOfUse_whereThereIsNoDirectory_doesNothing() throws {
        XCTAssertNil(try RetiredAccountDirectory.takeOutOfUse(root.appendingPathComponent("Messages")))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: root.path), [])
    }

    // Revert-check: the `catch` in `takeOutOfUse` that empties the directory in place.
    // Rethrow the rename's error there and a sign-out on a volume where the rename fails
    // can never finish its cleanup.
    func testTakeOutOfUse_whenTheRenameFails_emptiesTheDirectoryInPlace() throws {
        let parent = root.appendingPathComponent("ReadOnlyParent", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let messages = parent.appendingPathComponent("Messages", isDirectory: true)
        try fileManager.createDirectory(at: messages, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: messages.appendingPathComponent("a.html"))
        // No entry of the parent can be renamed; the directory's own entries still can go.
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)

        let tombstone = try RetiredAccountDirectory.takeOutOfUse(messages)

        XCTAssertNil(tombstone)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: messages.path), [])
    }

    // Revert-check: the loop in `RetiredAccountDirectory.removeContents` that goes on after
    // a failure. Throw at the first failed removal, as the cleanup did before, and whatever
    // came after the locked folder in the listing is left.
    func testRemoveContents_goesOnPastAnItemThatCannotBeRemoved_andThenReportsIt() throws {
        let messages = try makeDirectory("Messages", files: ["a.html", "b.html", "y.html", "z.html"])
        try makeLockedFolder(named: "locked", in: messages)

        XCTAssertThrowsError(try RetiredAccountDirectory.removeContents(of: messages))

        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: messages.path), ["locked"])
    }

    // MARK: - Tombstones

    func testIsTombstone_isANameTheMarkerAndAUUID_andNothingElse() {
        let uuid = UUID().uuidString
        XCTAssertTrue(RetiredAccountDirectory.isTombstone(root.appendingPathComponent("Messages.deleting-\(uuid)")))
        XCTAssertFalse(RetiredAccountDirectory.isTombstone(root.appendingPathComponent("Messages")))
        XCTAssertFalse(RetiredAccountDirectory.isTombstone(root.appendingPathComponent("Messages.deleting-")))
        XCTAssertFalse(RetiredAccountDirectory.isTombstone(root.appendingPathComponent("Messages.deleting-backup")))
        XCTAssertFalse(RetiredAccountDirectory.isTombstone(root.appendingPathComponent(".deleting-\(uuid)")))
    }

    func testTombstonesOf_namesOnlyThatDirectorysTombstones() throws {
        let messages = root.appendingPathComponent("Messages", isDirectory: true)
        let mine = try makeDirectory("Messages.deleting-\(UUID().uuidString)", files: ["a.html"])
        _ = try makeDirectory("Messages", files: ["live.html"])
        _ = try makeDirectory("Messages.deleting-not-a-uuid", files: ["x"])
        _ = try makeDirectory("Attachments.deleting-\(UUID().uuidString)", files: ["x"])
        _ = try makeDirectory("MessagesArchive", files: ["x"])

        XCTAssertEqual(RetiredAccountDirectory.tombstones(of: messages).map(\.lastPathComponent), [mine.lastPathComponent])
    }

    // Revert-check: the `isTombstone` guard that opens `RetiredAccountDirectory.remove`.
    // Without it this removes the live directory it was handed.
    func testRemove_refusesAnythingThatIsNotNamedAsATombstone() throws {
        let messages = try makeDirectory("Messages", files: ["live.html"])

        XCTAssertFalse(RetiredAccountDirectory.remove(messages))

        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: messages.path), ["live.html"])
    }

    func testRemove_removesATombstoneWithItsFoldersAndItsReadOnlyFiles() throws {
        let tombstone = try makeDirectory("Attachments.deleting-\(UUID().uuidString)", files: ["a.bin"])
        // The Mac's read-only copies of opened attachments (`AttachmentOpenCopy`).
        let opened = tombstone.appendingPathComponent("Opened/one", isDirectory: true)
        try fileManager.createDirectory(at: opened, withIntermediateDirectories: true)
        let copy = opened.appendingPathComponent("Report.pdf")
        try Data("report".utf8).write(to: copy)
        try fileManager.setAttributes([.posixPermissions: AttachmentOpenCopy.readOnlyPermissions], ofItemAtPath: copy.path)

        XCTAssertTrue(RetiredAccountDirectory.remove(tombstone))

        XCTAssertFalse(fileManager.fileExists(atPath: tombstone.path))
    }

    // Revert-check: the `removeTree` fallback in `RetiredAccountDirectory.remove`. With
    // `removeItem` alone, which stops at the first item it cannot remove, files beside
    // the locked folder are left.
    func testRemove_goesOnPastAnItemThatCannotBeRemoved_andSaysTheTombstoneIsStillThere() throws {
        let tombstone = try makeDirectory(
            "Messages.deleting-\(UUID().uuidString)",
            files: ["a.html", "b.html", "y.html", "z.html"]
        )
        try makeLockedFolder(named: "locked", in: tombstone)

        XCTAssertFalse(RetiredAccountDirectory.remove(tombstone))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: tombstone.path), ["locked"])

        // The next launch's sweep, once whatever held the item has let go.
        restoreWritePermissions(under: tombstone)
        XCTAssertTrue(RetiredAccountDirectory.remove(tombstone))
        XCTAssertFalse(fileManager.fileExists(atPath: tombstone.path))
    }

    // Revert-check: the loop over `tombstones(of:)` in `RetiredAccountDirectory.sweepLeftovers`.
    // Without the launch sweep a tombstone whose removal the last run did not finish stays
    // for good, with a signed-out account's mail in it.
    //
    // The sweep's task is awaited, never polled for against a deadline: it runs at
    // background priority, and on CI it twice had not finished after a 5-second wait
    // (PRs 463 and 470) while it passed every local run.
    func testSweepLeftovers_removesTheTombstonesAnEarlierRunLeft_andNothingElse() async throws {
        let messages = try makeDirectory("Messages", files: ["live.html"])
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        let leftMessages = try makeDirectory("Messages.deleting-\(UUID().uuidString)", files: ["old.html"])
        let leftAttachments = try makeDirectory("Attachments.deleting-\(UUID().uuidString)", files: ["old.bin"])
        let unrelated = try makeDirectory("Messages.deleting-not-a-uuid", files: ["keep"])

        let sweep = try XCTUnwrap(
            RetiredAccountDirectory.sweepLeftovers(beside: [messages, attachments]),
            "The sweep was refused, so nothing was started"
        )
        await sweep.value

        XCTAssertFalse(fileManager.fileExists(atPath: leftMessages.path), "The leftover Messages tombstone was not removed")
        XCTAssertFalse(
            fileManager.fileExists(atPath: leftAttachments.path),
            "The leftover Attachments tombstone was not removed"
        )
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: messages.path), ["live.html"])
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: unrelated.path), ["keep"])
    }

    // MARK: - The attachment folders

    // Revert-check: `RetiredAccountDirectory.takeOutOfUse` in
    // `AuthSession.retireAttachmentDirectories`. Remove the folders there, as before, and
    // nothing is handed to `removeTombstone`: the files were unlinked inside the call.
    func testRetireAttachmentDirectories_renamesEachFolder_andLeavesTheUnlinksToTheRemover() throws {
        let appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        for (parent, name) in [(appSupport, "Attachments"), (appSupport, "Previews"), (caches, "AttachmentCache")] {
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: directory.appendingPathComponent("file.bin"))
        }
        XCTAssertTrue(
            AccountScopedMailboxFileInspector.hasStoredFiles(appSupportDirectory: appSupport, cachesDirectory: caches)
        )
        var handedOver: [URL] = []

        try AuthSession.retireAttachmentDirectories(
            appSupportDirectory: appSupport,
            cachesDirectory: caches,
            removeTombstone: { tombstone in
                if let tombstone { handedOver.append(tombstone) }
            }
        )

        XCTAssertEqual(handedOver.count, 3)
        for tombstone in handedOver {
            XCTAssertEqual(
                try fileManager.contentsOfDirectory(atPath: tombstone.path),
                ["file.bin"],
                "\(tombstone.lastPathComponent) must still hold its file when the cleanup returns"
            )
        }
        XCTAssertEqual(
            Set(try fileManager.contentsOfDirectory(atPath: appSupport.path).map { $0.components(separatedBy: ".").first }),
            ["Attachments", "Previews"]
        )
        XCTAssertFalse(fileManager.fileExists(atPath: appSupport.appendingPathComponent("Attachments").path))
        XCTAssertFalse(fileManager.fileExists(atPath: appSupport.appendingPathComponent("Previews").path))

        // The tombstone policy: files in a tombstone are not another account's files to
        // clean up. Counted, they would make the sign-in after a sign-out reset the store
        // again while the removal was still running.
        XCTAssertFalse(
            AccountScopedMailboxFileInspector.hasStoredFiles(appSupportDirectory: appSupport, cachesDirectory: caches)
        )
    }

    // Revert-check: the `do`/`catch` around each folder in `retireAttachmentDirectories`.
    // Let the first failure leave the loop and `Previews`, which comes after `Attachments`,
    // keeps the signed-out account's files.
    func testRetireAttachmentDirectories_whenOneFolderFails_stillRetiresTheOthers_andThrows() throws {
        let appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        for name in ["Attachments", "Previews"] {
            let directory = appSupport.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: directory.appendingPathComponent("file.bin"))
        }
        // `Attachments` can be neither renamed nor emptied.
        let failing = FolderRefusingFileManager(refusedFolder: "Attachments")
        var handedOver: [URL] = []

        XCTAssertThrowsError(
            try AuthSession.retireAttachmentDirectories(
                appSupportDirectory: appSupport,
                cachesDirectory: nil,
                fileManager: failing,
                removeTombstone: { tombstone in
                    if let tombstone { handedOver.append(tombstone) }
                }
            )
        )

        XCTAssertEqual(handedOver.map { $0.lastPathComponent.components(separatedBy: ".").first }, ["Previews"])
        XCTAssertFalse(fileManager.fileExists(atPath: appSupport.appendingPathComponent("Previews").path))
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: appSupport.appendingPathComponent("Attachments").path),
            ["file.bin"]
        )
    }

    // MARK: - Helpers

    private func makeDirectory(_ name: String, files: [String]) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: directory.appendingPathComponent(file))
        }
        return directory
    }

    /// A folder whose one file cannot be removed: the folder gives no write permission, so
    /// neither its entry nor, with an entry in it, the folder itself can go.
    private func makeLockedFolder(named name: String, in directory: URL) throws {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("held".utf8).write(to: folder.appendingPathComponent("held.bin"))
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    }

    private func restoreWritePermissions(under directory: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func fileNumber(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }
}

/// A file manager that can neither rename one folder nor remove anything in it.
private final class FolderRefusingFileManager: FileManager {
    private let refusedFolder: String

    init(refusedFolder: String) {
        self.refusedFolder = refusedFolder
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == refusedFolder {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        if URL.deletingLastPathComponent().lastPathComponent == refusedFolder {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
