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

        XCTAssertEqual(first.url.lastPathComponent, "Pasted Image.png")
        XCTAssertEqual(second.url.lastPathComponent, "Pasted Image.png")
        XCTAssertEqual(try Data(contentsOf: first.url), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("two".utf8))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(folders().count, 2)
        // Each is in a folder named by a UUID, under the directory it was given.
        for file in [first, second] {
            let folder = file.url.deletingLastPathComponent()
            XCTAssertNotNil(UUID(uuidString: folder.lastPathComponent))
            XCTAssertEqual(
                folder.deletingLastPathComponent().standardizedFileURL,
                directory.standardizedFileURL
            )
        }
    }

    /// Revert-check: removing only the file, and not its folder, in `PastedImageFile.remove`
    /// makes this fail: an empty folder is left for every image ever pasted.
    func testRemove_takesTheFileAndItsFolder_andLeavesTheOthers() throws {
        let first = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        let second = try PastedImageFile.write(Data("two".utf8), fileExtension: "jpg", in: directory)

        PastedImageFile.remove([first])

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(folders(), [second.url.deletingLastPathComponent().lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: second.url), Data("two".utf8))
    }

    /// A file can be gone before its folder is: anything that removes the file alone leaves
    /// the folder, which was only ever for that file.
    ///
    /// Revert-check: deleting the `contents.isEmpty` branch from `PastedImageFile.remove`
    /// makes this fail: the empty folder stays until the next launch.
    func testRemove_aFileAlreadyGone_takesItsEmptyFolder() throws {
        let file = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        try FileManager.default.removeItem(at: file.url)
        XCTAssertEqual(folders().count, 1)

        PastedImageFile.remove([file])

        XCTAssertEqual(folders(), [])
    }

    func testRemove_aFileRemovedBefore_doesNothing() throws {
        let file = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        PastedImageFile.remove([file])

        PastedImageFile.remove([file])

        XCTAssertEqual(folders(), [])
    }

    // MARK: - What `remove` leaves alone

    /// `write` puts each file in a folder of its own, so a folder that holds anything else
    /// is not as `write` left it, with the file still there or gone.
    ///
    /// Revert-check: removing the folder whatever it holds
    /// (`contents.contains(file.url.lastPathComponent)` in `PastedImageFile.remove`) makes
    /// the first group fail, and removing it with `removeItem` wherever the file is gone
    /// makes the second fail: the other file goes with the folder.
    func testRemove_aFolderThatHoldsAnythingElse_isLeft() throws {
        let beside = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        let besideFolder = beside.url.deletingLastPathComponent()
        try Data("other".utf8).write(to: besideFolder.appendingPathComponent("Notes.txt"))
        let replaced = try PastedImageFile.write(Data("two".utf8), fileExtension: "png", in: directory)
        let replacedFolder = replaced.url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: replaced.url)
        try Data("other".utf8).write(to: replacedFolder.appendingPathComponent("Notes.txt"))

        PastedImageFile.remove([beside, replaced])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: besideFolder.path).sorted(),
            ["Notes.txt", "Pasted Image.png"]
        )
        XCTAssertEqual(try Data(contentsOf: beside.url), Data("one".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacedFolder.path), ["Notes.txt"])
    }

    /// One file passed over does not stop the others of a request being removed.
    ///
    /// Revert-check: leaving `PastedImageFile.remove` at the first file it passes over
    /// (`return` in place of going on to the next) makes this fail: the second file stays.
    func testRemove_passesOverAFolderItLeaves_andStillTakesTheNext() throws {
        let kept = try PastedImageFile.write(Data("one".utf8), fileExtension: "png", in: directory)
        let keptFolder = kept.url.deletingLastPathComponent()
        try Data("other".utf8).write(to: keptFolder.appendingPathComponent("Notes.txt"))
        let gone = try PastedImageFile.write(Data("two".utf8), fileExtension: "png", in: directory)
        try FileManager.default.removeItem(at: gone.url.deletingLastPathComponent())
        let written = try PastedImageFile.write(Data("three".utf8), fileExtension: "png", in: directory)

        PastedImageFile.remove([kept, gone, written])

        XCTAssertEqual(folders(), [keptFolder.lastPathComponent])
    }

    /// Only `write` makes a `PastedImageFile`, so a request's temporary files cannot hold a
    /// file of the user's own, and `remove` cannot be handed one. This is the compiler's to
    /// enforce; the test reads the source so that CI says so if the initializer is opened.
    ///
    /// Revert-check: making the initializer of `PastedImageFile` internal (dropping
    /// `private`) makes the first assertion fail. The last assertion says what a request's
    /// temporary files must be; with `[URL]` there the app does not compile as it stands.
    func testOnlyWriteMakesOne_andARequestCarriesNothingElse() throws {
        let file = try source("esc-chatmail/Views/Components/PastedImageFile.swift")
        let request = try source("esc-chatmail/Views/Components/DraftFileDrop.swift")

        XCTAssertTrue(file.contains("    private init(url: URL) {\n"))
        XCTAssertEqual(file.components(separatedBy: "PastedImageFile(url: ").count - 1, 1)
        XCTAssertTrue(request.contains("    let temporaryFiles: [PastedImageFile]\n"))
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

    private func source(_ relativePath: String) throws -> String {
        // This file is esc-chatmailTests/Views/, so the repo root is three directories up.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
