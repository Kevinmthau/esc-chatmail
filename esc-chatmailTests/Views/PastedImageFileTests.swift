import XCTest
@testable import esc_chatmail

/// The file a pasted image is written to (`PastedImageFile`), in a directory of the test's
/// own: it runs in the Mac plan too, where the test host's container is the real one.
final class PastedImageFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastedImageFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func folders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Revert-check: writing straight into `directory` in `PastedImageFile.write`, with no
    /// folder of its own, makes the last assertion fail: a second paste would replace the
    /// first one's file while it was being imported.
    func testWrite_namesTheFileForAPastedImage_inAFolderOfItsOwn() throws {
        let first = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        let second = try PastedImageFile.write(Data("two".utf8), fileExtension: "png", in: directory)

        XCTAssertEqual(first.lastPathComponent, "Pasted Image.png")
        XCTAssertEqual(second.lastPathComponent, "Pasted Image.png")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(folders().count, 2)
    }

    /// Revert-check: removing only the file, and not its folder, in `PastedImageFile.remove`
    /// makes this fail: an empty folder is left for every image ever pasted.
    func testRemove_takesTheFileAndItsFolder_andLeavesTheOthers() throws {
        let first = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        let second = try PastedImageFile.write(Data("two".utf8), fileExtension: "tiff", in: directory)

        PastedImageFile.remove([first])

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(folders(), [second.deletingLastPathComponent().lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    func testRemove_aFileAlreadyGone_doesNothing() throws {
        let file = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        PastedImageFile.remove([file])

        PastedImageFile.remove([file])

        XCTAssertEqual(folders(), [])
    }

    // MARK: - What `remove` leaves alone

    /// A file in `folderName` under the test's directory, with `others` beside it.
    private func makeFile(named name: String, inFolder folderName: String, beside others: [String] = []) throws -> URL {
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for other in others {
            try Data("other".utf8).write(to: folder.appendingPathComponent(other))
        }
        let file = folder.appendingPathComponent(name, isDirectory: false)
        try Data("kept".utf8).write(to: file)
        return file
    }

    /// `remove` takes the folder a file is in, so it must be a folder `write` made. A file of
    /// the user's own that reached it would take the user's folder with it, and one written
    /// straight into the temporary directory would take everything the app keeps there.
    ///
    /// Revert-check: dropping the `UUID(uuidString:)` term from
    /// `PastedImageFile.isAloneInAFolderOfItsOwn` makes this fail: the folder is removed.
    func testRemove_aFileInAFolderNotNamedByAUUID_isLeftWithItsFolder() throws {
        let file = try makeFile(named: "Pasted Image.png", inFolder: "Screenshots")

        PastedImageFile.remove([file])

        XCTAssertEqual(try Data(contentsOf: file), Data("kept".utf8))
        XCTAssertEqual(folders(), ["Screenshots"])
    }

    /// Revert-check: dropping the `== baseName` term from
    /// `PastedImageFile.isAloneInAFolderOfItsOwn` makes the first file fail, and dropping
    /// the `pathExtension.isEmpty` term makes the second fail: each is removed with its folder.
    func testRemove_aFileWithAnotherName_isLeftWithItsFolder() throws {
        let renamed = try makeFile(named: "Report.pdf", inFolder: UUID().uuidString)
        let bare = try makeFile(named: "Pasted Image", inFolder: UUID().uuidString)

        PastedImageFile.remove([renamed, bare])

        XCTAssertEqual(try Data(contentsOf: renamed), Data("kept".utf8))
        XCTAssertEqual(try Data(contentsOf: bare), Data("kept".utf8))
        XCTAssertEqual(folders().count, 2)
    }

    /// `write` puts each file in a folder of its own, so a folder that holds anything else is
    /// not one of its.
    ///
    /// Revert-check: answering true from `PastedImageFile.isAloneInAFolderOfItsOwn` whatever
    /// the folder holds (`return contents.contains(file.lastPathComponent)`) makes this fail:
    /// the other file goes with the folder.
    func testRemove_aFileThatIsNotAloneInItsFolder_isLeftWithItsFolder() throws {
        let folder = UUID().uuidString
        let file = try makeFile(named: "Pasted Image.png", inFolder: folder, beside: ["Notes.txt"])

        PastedImageFile.remove([file])

        XCTAssertEqual(try Data(contentsOf: file), Data("kept".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).sorted(),
            ["Notes.txt", "Pasted Image.png"]
        )
    }

    /// One refused file does not stop the others of a request being removed.
    ///
    /// Revert-check: leaving `PastedImageFile.remove` at the first file it passes over
    /// (`guard isAloneInAFolderOfItsOwn(…) else { return }` in place of the `where`) makes
    /// this fail: the written file stays.
    func testRemove_passesOverWhatItDidNotWrite_andStillTakesWhatItDid() throws {
        let kept = try makeFile(named: "Pasted Image.png", inFolder: "Screenshots")
        let written = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)

        PastedImageFile.remove([kept, written])

        XCTAssertEqual(folders(), ["Screenshots"])
        XCTAssertEqual(try Data(contentsOf: kept), Data("kept".utf8))
    }

    /// Revert-check: deleting the `removeItem` call from `PastedImageFile.removeAll` makes
    /// this fail.
    func testRemoveAll_takesEveryPastedImage() throws {
        _ = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        _ = try PastedImageFile.write(Data("two".utf8), fileExtension: "png", in: directory)

        PastedImageFile.removeAll(in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The app's own are in the temporary directory, in one folder that a launch removes.
    ///
    /// Revert-check: answering the temporary directory itself from
    /// `PastedImageFile.directory` makes this fail, and `removeAll` would then remove
    /// everything the app keeps there.
    func testDirectory_isAFolderOfItsOwnInTheTemporaryDirectory() {
        let directory = PastedImageFile.directory()

        XCTAssertEqual(directory.lastPathComponent, "PastedImages")
        XCTAssertEqual(
            directory.deletingLastPathComponent().standardizedFileURL,
            FileManager.default.temporaryDirectory.standardizedFileURL
        )
    }
}
