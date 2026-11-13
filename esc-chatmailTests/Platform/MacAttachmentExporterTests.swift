#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// Save Attachment… and Save All Attachments… on the Mac (`MacAttachmentExporter`), with
/// stand-ins for the save panel, the folder panel and the alert. Mac only, so it runs in
/// `Mac.xctestplan`; every file is in a temporary directory.
///
/// HONEST SCOPE: the three real ones (`MacAttachmentSavePanels`) are never shown here, and no
/// Mac build of the app has been launched. That a panel comes up as a sheet, offers the name,
/// and returns a place the sandbox lets the app write to is not pinned by anything.
@MainActor
final class MacAttachmentExporterTests: XCTestCase {
    /// What the exporter asked for, and what the user is to answer.
    @MainActor
    private final class Panels {
        var fileAnswer: URL?
        var folderAnswer: URL?
        private(set) var offeredFilenames: [String] = []
        private(set) var folderCounts: [Int] = []
        private(set) var alerts: [String] = []

        func makeExporter() -> MacAttachmentExporter {
            MacAttachmentExporter(
                chooseFile: { name in
                    self.offeredFilenames.append(name)
                    return self.fileAnswer
                },
                chooseFolder: { count in
                    self.folderCounts.append(count)
                    return self.folderAnswer
                },
                presentFailure: { title, message in
                    self.alerts.append("\(title)|\(message)")
                }
            )
        }
    }

    private var directory: URL!
    private var chosenFolder: URL!
    private var panels: Panels!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAttachmentExporterTests-\(UUID().uuidString)", isDirectory: true)
        chosenFolder = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenFolder, withIntermediateDirectories: true)
        panels = Panels()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        panels = nil
        try await super.tearDown()
    }

    private func item(stored: String, filename: String, bytes: String) throws -> AttachmentExportItem {
        let url = directory.appendingPathComponent(stored)
        try Data(bytes.utf8).write(to: url)
        return AttachmentExportItem(sourceURL: url, filename: filename)
    }

    private func savedNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: chosenFolder.path).sorted()
    }

    // MARK: - Save Attachment…

    /// Revert-check: passing `item.sourceURL.lastPathComponent` to `chooseFile` makes the
    /// first assertion fail; deleting the `AttachmentFileExport.save` call makes the second.
    func testSave_offersTheAttachmentsName_andWritesWhereTheUserChose() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "report bytes")
        let destination = chosenFolder.appendingPathComponent("Renamed.pdf")
        panels.fileAnswer = destination

        await panels.makeExporter().save(item, displayFilename: "Report.pdf")

        XCTAssertEqual(panels.offeredFilenames, ["Report.pdf"])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "report bytes")
        XCTAssertEqual(panels.alerts, [])
    }

    /// Revert-check: writing to a default place when `chooseFile` answers nil makes this fail.
    func testSave_cancelled_writesNothing_andSaysNothing() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        panels.fileAnswer = nil

        await panels.makeExporter().save(item, displayFilename: "Report.pdf")

        XCTAssertEqual(panels.offeredFilenames, ["Report.pdf"])
        XCTAssertEqual(try savedNames(), [])
        XCTAssertEqual(panels.alerts, [])
    }

    /// Revert-check: returning from `save` without `present` when the item is nil makes this
    /// fail: the menu entry would do nothing and say nothing.
    func testSave_anAttachmentWithNoFile_saysSo_andOpensNoPanel() async {
        await panels.makeExporter().save(nil, displayFilename: "Report.pdf")

        XCTAssertEqual(panels.offeredFilenames, [])
        XCTAssertEqual(panels.alerts, ["Attachment Not Saved|Report.pdf is no longer on this Mac."])
    }

    /// The file can go between the menu and the end of the panel: a sign-out deletes it.
    ///
    /// Revert-check: dropping the `if let failure { present([failure]) }` from `save` makes
    /// this fail.
    func testSave_whenTheFileGoesWhileThePanelIsOpen_saysSo() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: "bytes")
        try FileManager.default.removeItem(at: item.sourceURL)
        panels.fileAnswer = chosenFolder.appendingPathComponent("Report.pdf")

        await panels.makeExporter().save(item, displayFilename: "Report.pdf")

        XCTAssertEqual(try savedNames(), [])
        XCTAssertEqual(panels.alerts, ["Attachment Not Saved|Report.pdf is no longer on this Mac."])
    }

    // MARK: - Save All Attachments…

    /// Revert-check: passing a fixed count to `chooseFolder` makes the first assertion fail;
    /// deleting the `AttachmentFileExport.saveAll` call makes the second.
    func testSaveAll_asksForOneFolder_andSavesEveryFileIntoIt() async throws {
        let items = [
            try item(stored: "remote_1.jpg", filename: "image.jpg", bytes: "one"),
            try item(stored: "remote_2.jpg", filename: "image.jpg", bytes: "two"),
            try item(stored: "remote_3.pdf", filename: "Tickets.pdf", bytes: "three")
        ]
        panels.folderAnswer = chosenFolder

        await panels.makeExporter().saveAll(items)

        XCTAssertEqual(panels.folderCounts, [3])
        XCTAssertEqual(try savedNames(), ["Tickets.pdf", "image 2.jpg", "image.jpg"])
        XCTAssertEqual(panels.offeredFilenames, [])
        XCTAssertEqual(panels.alerts, [])
    }

    func testSaveAll_cancelled_writesNothing_andSaysNothing() async throws {
        let items = [try item(stored: "remote_1.jpg", filename: "image.jpg", bytes: "one")]
        panels.folderAnswer = nil

        // A missing file is not reported for a save the user called off.
        await panels.makeExporter().saveAll(items, missingFilenames: ["Gone.pdf"])

        XCTAssertEqual(panels.folderCounts, [1])
        XCTAssertEqual(try savedNames(), [])
        XCTAssertEqual(panels.alerts, [])
    }

    /// Revert-check: presenting only `failures` after `saveAll`, without `missing`, makes this
    /// fail.
    func testSaveAll_listsWhatItCouldNotSave_afterSavingTheRest() async throws {
        let gone = try item(stored: "remote_2.pdf", filename: "Deleted.pdf", bytes: "x")
        try FileManager.default.removeItem(at: gone.sourceURL)
        let items = [try item(stored: "remote_1.jpg", filename: "Beach.jpg", bytes: "one"), gone]
        panels.folderAnswer = chosenFolder

        await panels.makeExporter().saveAll(items, missingFilenames: ["Gone.pdf"])

        XCTAssertEqual(try savedNames(), ["Beach.jpg"])
        XCTAssertEqual(panels.alerts, [
            "Some Attachments Weren’t Saved|"
                + "Deleted.pdf is no longer on this Mac.\nGone.pdf is no longer on this Mac."
        ])
    }

    /// Revert-check: asking for a folder before checking that there is anything to save makes
    /// the first assertion fail.
    func testSaveAll_withNothingToSave_opensNoPanel_andNamesWhatIsMissing() async {
        await panels.makeExporter().saveAll([], missingFilenames: ["Gone.pdf"])

        XCTAssertEqual(panels.folderCounts, [])
        XCTAssertEqual(panels.alerts, ["Attachment Not Saved|Gone.pdf is no longer on this Mac."])

        await panels.makeExporter().saveAll([])

        XCTAssertEqual(panels.folderCounts, [])
        XCTAssertEqual(panels.alerts.count, 1)
    }
}
#endif
