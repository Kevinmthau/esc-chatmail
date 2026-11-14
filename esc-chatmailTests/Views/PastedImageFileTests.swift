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
