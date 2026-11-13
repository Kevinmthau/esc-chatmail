#if os(macOS)
import XCTest
@testable import esc_chatmail

/// `MacAttachmentOpener`, with its three closures replaced: the copy is made in a temporary
/// directory, and nothing is handed to `NSWorkspace`.
///
/// HONEST SCOPE: no app is launched and no alert is shown. That `NSWorkspace` opens a file
/// from the app's container for another app, in the sandbox, has not been seen.
@MainActor
final class MacAttachmentOpenerTests: XCTestCase {
    private var directory: URL!
    private var opened: [URL] = []
    private var alerts: [String] = []
    private var systemOpens = true

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAttachmentOpenerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        opened = []
        alerts = []
        systemOpens = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func item(stored: String, filename: String, bytes: String? = "bytes") throws -> AttachmentExportItem {
        let url = directory.appendingPathComponent(stored)
        if let bytes {
            try Data(bytes.utf8).write(to: url)
        }
        return AttachmentExportItem(sourceURL: url, filename: filename)
    }

    private func makeOpener(copyFails: Bool = false) -> MacAttachmentOpener {
        let copies = directory.appendingPathComponent("Opened", isDirectory: true)
        let recorder = CopyRecorder()
        self.recorder = recorder
        return MacAttachmentOpener(
            makeCopy: { item in
                recorder.record(item.filename)
                if copyFails {
                    throw AttachmentFileExport.ExportError.copyFailed(filename: item.filename, reason: "The disk is full.")
                }
                return try AttachmentOpenCopy.prepare(item, in: copies)
            },
            openFile: { url in
                self.opened.append(url)
                return self.systemOpens
            },
            presentFailure: { title, message in
                self.alerts.append("\(title)|\(message)")
            }
        )
    }

    private var recorder: CopyRecorder?

    // MARK: - Opening

    /// Revert-check: handing `item.sourceURL` to `openFile` in `MacAttachmentOpener.open`
    /// makes this fail: the other app would be given the app's own file.
    func testOpen_opensTheCopy_underTheAttachmentsName() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Q3 report.pdf", bytes: "report")
        let opener = makeOpener()

        await opener.open(item, displayFilename: "Q3 report.pdf")

        XCTAssertEqual(opened.map(\.lastPathComponent), ["Q3 report.pdf"])
        let copy = try XCTUnwrap(opened.first)
        XCTAssertNotEqual(copy.standardizedFileURL, item.sourceURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "report")
        XCTAssertEqual(alerts, [])
    }

    // MARK: - Refusing

    /// The menu offers Open only for a kind that is opened. The opener asks for itself, so
    /// the rule holds whatever calls it.
    ///
    /// Revert-check: deleting the `guard AttachmentOpenPolicy.isOpenable(filename:
    /// item.filename)` from `MacAttachmentOpener.open` makes this fail: the installer is
    /// copied and handed to the system.
    func testOpen_aKindThatIsNotOpened_isRefusedBeforeAnythingIsCopied() async throws {
        let opener = makeOpener()

        for name in ["Setup.pkg", "run.command", "page.html", "Makefile"] {
            await opener.open(try item(stored: "remote_\(name)", filename: name), displayFilename: name)
        }

        XCTAssertEqual(opened, [])
        XCTAssertEqual(recorder?.filenames, [])
        XCTAssertEqual(alerts.count, 4)
        XCTAssertEqual(
            alerts.first,
            "Attachment Not Opened|MushMail does not open files like Setup.pkg. Save it, and open it from the Finder."
        )
    }

    /// Revert-check: returning without `present` when `item` is nil in
    /// `MacAttachmentOpener.open` makes this fail: the menu entry would do nothing and not
    /// say why.
    func testOpen_anAttachmentWithNoFile_saysSo() async {
        let opener = makeOpener()

        await opener.open(nil, displayFilename: "Report.pdf")

        XCTAssertEqual(opened, [])
        XCTAssertEqual(alerts, ["Attachment Not Opened|Report.pdf is no longer on this Mac."])
    }

    /// A sign-out between the click and the copy deletes the file.
    func testOpen_whenTheFileGoesBeforeTheCopy_saysSo() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf", bytes: nil)
        let opener = makeOpener()

        await opener.open(item, displayFilename: "Report.pdf")

        XCTAssertEqual(opened, [])
        XCTAssertEqual(alerts, ["Attachment Not Opened|Report.pdf is no longer on this Mac."])
    }

    /// Revert-check: doing nothing for a failed copy in `MacAttachmentOpener.open`, in place
    /// of presenting the failure, makes this fail.
    func testOpen_whenTheCopyFails_opensNothing_andSaysWhy() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf")
        let opener = makeOpener(copyFails: true)

        await opener.open(item, displayFilename: "Report.pdf")

        XCTAssertEqual(opened, [])
        XCTAssertEqual(alerts, ["Attachment Not Opened|Report.pdf could not be opened. The disk is full."])
    }

    /// Revert-check: ignoring `openFile`'s answer in `MacAttachmentOpener.open` makes this
    /// fail.
    func testOpen_whenTheSystemOpensNothing_saysSo() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf")
        let opener = makeOpener()
        systemOpens = false

        await opener.open(item, displayFilename: "Report.pdf")

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(
            alerts,
            ["Attachment Not Opened|Report.pdf could not be opened. No app on this Mac opened it."]
        )
    }
}

/// What the copy closure was asked for. It runs off the main thread, so the list is behind
/// a lock.
private final class CopyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ filename: String) {
        lock.lock()
        recorded.append(filename)
        lock.unlock()
    }

    var filenames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
#endif
