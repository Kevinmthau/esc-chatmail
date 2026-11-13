#if os(macOS)
import XCTest
@testable import esc_chatmail

/// `MacAttachmentOpener`, with its three closures replaced: the copy is made in a temporary
/// directory, and nothing is handed to `NSWorkspace`. Each opener has an account boundary of
/// its own (`AttachmentAccountWorkRegistry`): the shared one is the process's.
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

    /// - Parameters:
    ///   - registry: The opener's account boundary; open, unless the test gives another.
    ///   - gate: Holds the copy where it starts until the test lets it go.
    private func makeOpener(
        copyFails: Bool = false,
        registry: AttachmentAccountWorkRegistry = AttachmentAccountWorkRegistry(),
        gate: CopyGate? = nil
    ) -> MacAttachmentOpener {
        let copies = directory.appendingPathComponent("Opened", isDirectory: true)
        let recorder = CopyRecorder()
        self.recorder = recorder
        return MacAttachmentOpener(
            makeCopy: { item in
                recorder.record(item.filename)
                gate?.holdCopy()
                defer { gate?.note("copy finished") }
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
            },
            registry: registry
        )
    }

    private var recorder: CopyRecorder?

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for a condition")
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

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

    // MARK: - The account boundary

    /// The copy is written into `Attachments`, which sign-out removes once it has drained the
    /// account's attachment work. With the boundary closed nothing may write there.
    ///
    /// Revert-check: making the copy in a bare `Task.detached` in `MacAttachmentOpener.open`,
    /// with no admission token asked for, makes this fail: the file is copied and opened.
    ///
    /// HONEST SCOPE: the boundary is asked twice, for the token and by the registry when the
    /// operation starts, and taking out either one alone leaves this passing.
    func testOpen_whenTheAccountBoundaryIsClosed_copiesNothing_andOpensNothing() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf")
        let opener = makeOpener(registry: AttachmentAccountWorkRegistry(admissionOpen: false))

        await opener.open(item, displayFilename: "Report.pdf")

        XCTAssertEqual(recorder?.filenames, [])
        XCTAssertEqual(opened, [])
        XCTAssertEqual(alerts, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Opened").path))
    }

    /// Sign-out drains the registry before it removes `Attachments`, so a copy in flight is
    /// waited for, and the Open it belonged to opens nothing: the account is leaving.
    ///
    /// Revert-check: making the copy in a bare `Task.detached` in `MacAttachmentOpener.open`,
    /// in place of `registry.startDetachedOperation`, makes this fail: the drain returns while
    /// the copy is still being made, so "drained" comes before "copy finished".
    ///
    /// HONEST SCOPE: that nothing is opened is held here by the operation's own
    /// `generation.isActive` check. The admission token asked again after the copy covers a
    /// sign-out that begins after the operation has ended and before the Open goes on, which
    /// no test here can place.
    func testOpen_whenASignOutBeginsDuringTheCopy_theSignOutWaitsForTheCopy_andNothingIsOpened() async throws {
        let item = try item(stored: "remote_abc.pdf", filename: "Report.pdf")
        let registry = AttachmentAccountWorkRegistry()
        let gate = CopyGate()
        let opener = makeOpener(registry: registry, gate: gate)

        let open = Task { await opener.open(item, displayFilename: "Report.pdf") }
        try await waitUntil { gate.events == ["copy started"] }
        let drain = Task {
            await registry.cancelAndAwaitAll()
            gate.note("drained")
        }
        try await waitUntil { registry.captureAdmissionToken() == nil }
        gate.release()
        await drain.value
        await open.value

        XCTAssertEqual(gate.events, ["copy started", "copy finished", "drained"])
        XCTAssertEqual(opened, [])
        XCTAssertEqual(alerts, [])
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

/// Holds a copy where it starts until the test lets it go, and keeps the order things
/// happened in. The copy runs off the main thread, so both are behind a lock.
private final class CopyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let released = DispatchSemaphore(value: 0)

    /// Called by the copy: notes that it started, and waits to be let go.
    func holdCopy() {
        note("copy started")
        released.wait()
    }

    func release() {
        released.signal()
    }

    func note(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
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
