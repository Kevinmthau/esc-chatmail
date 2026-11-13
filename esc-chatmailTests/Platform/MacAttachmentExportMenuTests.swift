#if os(macOS)
import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The menu a right-click on an attachment opens in a Mac chat (`MacAttachmentExportMenu`),
/// read from AppKit: the hosting view is asked for the menu of a right-click at a point, which
/// is how the menu the user sees is found. Mac only, so it runs in `Mac.xctestplan`.
///
/// The stand-in row has what the transcript's row has around an attachment: a context menu of
/// its own, with a preview, whose entries it also hands down to the views inside it
/// (`View.macEnclosingMessageMenu`).
///
/// HONEST SCOPE: no menu is opened and nothing is clicked. The modifier is mounted on a
/// colored square, not on the app's attachment views (`AttachmentGridView` loads thumbnails
/// and starts downloads as it appears); that those views carry it is
/// `AttachmentExportSourceTests`' to pin, and that the transcript's row hands its entries down
/// is `MacEnclosingMessageMenuSourceTests`'. The save panel is a stand-in, and Open hands
/// its copy to a closure, never to `NSWorkspace`. None of it has been seen in the app.
@MainActor
final class MacAttachmentExportMenuTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var directory: URL!
    private var harnesses: [Harness] = []

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAttachmentExportMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        harnesses.forEach { $0.close() }
        harnesses = []
        try? FileManager.default.removeItem(at: directory)
        context = nil
        stack = nil
        try await super.tearDown()
    }

    private func attachment(
        _ filename: String,
        state: Attachment.State = .downloaded,
        bytes: String? = "bytes"
    ) throws -> Attachment {
        try FileBackedAttachmentFixture.make(filename, state: state, bytes: bytes, in: context, directory: directory)
    }

    private func makeHarness(_ attachments: [Attachment], inAMessageRow: Bool = true) throws -> Harness {
        let harness = Harness(
            window: try makeTestHostWindow(),
            attachments: attachments,
            directory: directory,
            inAMessageRow: inAMessageRow
        )
        harnesses.append(harness)
        return harness
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("The condition was not met in \(timeout) s")
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    // MARK: - Which menu

    /// Revert-check: deleting the `contextMenu` from `MacAttachmentExportMenu.body` makes the
    /// first assertion fail: a right-click on the attachment opens the message's menu.
    /// Deleting the `if let messageMenu` block from it makes the first fail too: the
    /// attachment's menu has no Reply or Forward.
    func testRightClick_onAnAttachment_opensItsMenu_endingWithTheMessages_andOnTheRestOfTheRow_theMessages() throws {
        let harness = try makeHarness([try attachment("Report.pdf")])

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:on", "Open:on", "Save Attachment…:on", "---", "Reply:on", "Forward:on"]
        )
        XCTAssertEqual(try harness.menuEntries(at: harness.pointOnText), ["Reply:on", "Forward:on"])
    }

    /// The entries handed down are the row's own, and choosing one does what it does in the
    /// row's menu.
    ///
    /// Revert-check: deleting the `if let messageMenu` block from
    /// `MacAttachmentExportMenu.body` makes this fail: the attachment's menu has no Reply.
    func testReply_chosenFromAnAttachmentsMenu_isTheMessagesReply() throws {
        let harness = try makeHarness([try attachment("Beach.jpg"), try attachment("Tickets.pdf")])

        try harness.choose("Reply", at: harness.pointOnAttachment(1))
        try harness.choose("Forward", at: harness.pointOnText)

        XCTAssertEqual(harness.panels.messageActions, ["Reply", "Forward"])
        XCTAssertEqual(harness.panels.quickLooked, [])
    }

    /// An attachment drawn where no row hands it a message's entries has its own, with no
    /// separator after them.
    ///
    /// Revert-check: drawing the `Divider()` outside the `if let messageMenu` block makes
    /// this fail.
    func testMenu_ofAnAttachmentOutsideAMessageRow_hasItsOwnEntriesOnly() throws {
        let harness = try makeHarness([try attachment("Report.pdf")], inAMessageRow: false)

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:on", "Open:on", "Save Attachment…:on"]
        )
    }

    /// Revert-check: deleting `.disabled(!entry.isEnabled)` makes this fail.
    func testMenu_ofAnAttachmentStillDownloading_hasItsEntriesDisabled() throws {
        let harness = try makeHarness([try attachment("Report.pdf", state: .queued, bytes: nil)])

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:off", "Open:off", "Save Attachment…:off", "---", "Reply:on", "Forward:on"]
        )
    }

    /// Revert-check: passing `shownCount: 1` to `AttachmentExportPolicy.menu` makes the first
    /// assertion fail; passing `readyCount: 0` makes Save All read as off.
    func testMenu_whereTheMessageShowsSeveral_addsSaveAll_onEachOfThem() throws {
        let harness = try makeHarness([
            try attachment("Beach.jpg"),
            try attachment("Loading.png", state: .queued, bytes: nil)
        ])

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            [
                "Quick Look:on", "Open:on", "Save Attachment…:on", "Save All Attachments…:on",
                "---", "Reply:on", "Forward:on"
            ]
        )
        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(1)),
            [
                "Quick Look:off", "Open:off", "Save Attachment…:off", "Save All Attachments…:on",
                "---", "Reply:on", "Forward:on"
            ]
        )
    }

    /// Open is in the menu only for a kind of file that is opened (`AttachmentOpenPolicy`).
    ///
    /// Revert-check: passing `isOpenable: true` to `AttachmentExportPolicy.menu` in
    /// `MacAttachmentExportMenu.body` makes this fail: an installer's menu would offer Open.
    func testMenu_ofAKindThatIsNotOpened_hasNoOpen() throws {
        let harness = try makeHarness([try attachment("Setup.pkg"), try attachment("run.command")])

        for index in 0..<2 {
            XCTAssertEqual(
                try harness.menuEntries(at: harness.pointOnAttachment(index)),
                ["Quick Look:on", "Save Attachment…:on", "Save All Attachments…:on", "---", "Reply:on", "Forward:on"]
            )
        }
    }

    // MARK: - What the entries do

    /// Revert-check: calling `resolveItem` with `shownAttachments.first` in place of
    /// `attachment` in the `.open` case makes this fail: the second attachment's menu opens
    /// the first.
    func testOpen_opensACopyOfTheAttachmentThatWasClicked_underItsName() async throws {
        let harness = try makeHarness([
            try attachment("Beach.jpg", bytes: "beach"),
            try attachment("dir/Tickets.pdf", bytes: "tickets")
        ])

        try harness.choose("Open", at: harness.pointOnAttachment(1))
        try await waitUntil { !harness.panels.opened.isEmpty }

        let copy = try XCTUnwrap(harness.panels.opened.first)
        XCTAssertEqual(harness.panels.opened.count, 1)
        XCTAssertEqual(copy.lastPathComponent, "Tickets.pdf")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "tickets")
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: copy.path))
        XCTAssertEqual(harness.panels.alerts, [])
    }

    /// Revert-check: returning from the `.open` case when `resolveItem` answers nil makes this
    /// fail.
    func testOpen_whoseFileIsGone_saysSo() async throws {
        let harness = try makeHarness([try attachment("Report.pdf", bytes: nil)])

        try harness.choose("Open", at: harness.pointOnAttachment(0))
        try await waitUntil { !harness.panels.alerts.isEmpty }

        XCTAssertEqual(harness.panels.opened, [])
        XCTAssertEqual(harness.panels.alerts, ["Attachment Not Opened|Report.pdf is no longer on this Mac."])
    }

    /// Revert-check: calling `resolveItem` with `shownAttachments.first` in place of
    /// `attachment` in the `.save` case makes this fail: the second attachment's menu saves
    /// the first.
    func testSaveAttachment_savesTheAttachmentThatWasClicked_underItsName() async throws {
        let harness = try makeHarness([
            try attachment("Beach.jpg", bytes: "beach"),
            try attachment("dir/Tickets.pdf", bytes: "tickets")
        ])
        let destination = directory.appendingPathComponent("Saved.pdf")
        harness.panels.fileAnswer = destination

        try harness.choose("Save Attachment…", at: harness.pointOnAttachment(1))
        try await waitUntil { FileManager.default.fileExists(atPath: destination.path) }

        XCTAssertEqual(harness.panels.offeredFilenames, ["Tickets.pdf"])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "tickets")
        XCTAssertEqual(harness.panels.alerts, [])
    }

    /// Revert-check: returning from the `.save` case when `resolveItem` answers nil makes this
    /// fail.
    func testSaveAttachment_whoseFileIsGone_saysSo() async throws {
        let harness = try makeHarness([try attachment("Report.pdf", bytes: nil)])

        try harness.choose("Save Attachment…", at: harness.pointOnAttachment(0))
        try await waitUntil { !harness.panels.alerts.isEmpty }

        XCTAssertEqual(harness.panels.offeredFilenames, [])
        XCTAssertEqual(harness.panels.alerts, ["Attachment Not Saved|Report.pdf is no longer on this Mac."])
    }

    /// Revert-check: passing `[attachment]` in place of `shownAttachments` in the `.saveAll`
    /// case makes this fail.
    func testSaveAll_savesEveryAttachmentWithAFile_whicheverWasClicked() async throws {
        let harness = try makeHarness([
            try attachment("image.jpg", bytes: "one"),
            try attachment("image.jpg", bytes: "two"),
            try attachment("Loading.png", state: .queued, bytes: nil)
        ])
        let folder = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        harness.panels.folderAnswer = folder

        try harness.choose("Save All Attachments…", at: harness.pointOnAttachment(2))
        try await waitUntil {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count == 2
        }

        XCTAssertEqual(harness.panels.folderCounts, [2])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            ["image 2.jpg", "image.jpg"]
        )
        XCTAssertEqual(harness.panels.alerts, [])
    }

    /// Revert-check: deleting `onQuickLook()` from the `.quickLook` case makes this fail.
    func testQuickLook_opensTheAttachmentThatWasClicked() throws {
        let attachments = [try attachment("Beach.jpg"), try attachment("Tickets.pdf")]
        let harness = try makeHarness(attachments)

        try harness.choose("Quick Look", at: harness.pointOnAttachment(1))

        XCTAssertEqual(harness.panels.quickLooked, [attachments[1].objectID])
    }
}

// MARK: - Harness

/// What the menu asked for, and what the user is to answer.
@MainActor
private final class MenuPanels {
    var fileAnswer: URL?
    var folderAnswer: URL?
    var offeredFilenames: [String] = []
    var folderCounts: [Int] = []
    var alerts: [String] = []
    var quickLooked: [NSManagedObjectID] = []
    /// The copies the menu's Open handed to the system, which here opens nothing.
    var opened: [URL] = []
    /// The message's entries that were chosen, from either menu.
    var messageActions: [String] = []

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

    /// An opener whose copies go to `directory` and which hands nothing to `NSWorkspace`.
    func makeOpener(copiesIn directory: URL) -> MacAttachmentOpener {
        MacAttachmentOpener(
            makeCopy: { try AttachmentOpenCopy.prepare($0, in: directory) },
            openFile: { url in
                self.opened.append(url)
                return true
            },
            presentFailure: { title, message in
                self.alerts.append("\(title)|\(message)")
            }
        )
    }
}

/// The suite's harness: the shared row stand-in (`MacMessageRowStandIn`) with the real menu
/// modifier on a colored square for each attachment, in the shared off-screen host.
@MainActor
private final class Harness {
    private static let columns = 3

    let panels: MenuPanels
    private let host: MacOffscreenHost

    init(window: NSWindow, attachments: [Attachment], directory: URL, inAMessageRow: Bool) {
        let panels = MenuPanels()
        self.panels = panels
        let exporter = panels.makeExporter()
        let opener = panels.makeOpener(copiesIn: directory.appendingPathComponent("Opened", isDirectory: true))
        let cell = MacMessageRowStandInLayout.cell
        host = MacOffscreenHost(
            window: window,
            size: MacMessageRowStandInLayout.size(columns: Self.columns),
            rootView: MacMessageRowStandIn(
                columns: Self.columns,
                inAMessageRow: inAMessageRow,
                onMessageAction: { panels.messageActions.append($0) },
                attachments: {
                    ForEach(attachments, id: \.objectID) { attachment in
                        Color.red
                            .frame(width: cell, height: cell)
                            .modifier(
                                MacAttachmentExportMenu(
                                    attachment: attachment,
                                    shownAttachments: attachments,
                                    onQuickLook: { panels.quickLooked.append(attachment.objectID) },
                                    exporter: exporter,
                                    opener: opener,
                                    resolveItem: { attachment in
                                        AttachmentExportItem(
                                            attachment: attachment,
                                            resolveURL: { $0.map { directory.appendingPathComponent($0) } }
                                        )
                                    }
                                )
                            )
                    }
                }
            )
        )
        // SwiftUI finishes its first update on a later turn of the run loop.
        host.settle()
    }

    var pointOnText: NSPoint {
        MacMessageRowStandInLayout.pointOnText(columns: Self.columns)
    }

    func pointOnAttachment(_ index: Int) -> NSPoint {
        MacMessageRowStandInLayout.pointOnAttachment(index)
    }

    /// The entries of the menu AppKit would open for a right-click at `point`.
    func menuEntries(at point: NSPoint) throws -> [String] {
        host.entries(of: try XCTUnwrap(try host.menu(at: point), "No menu at \(point)"))
    }

    /// Chooses the entry titled `title`, as a click on it would.
    func choose(_ title: String, at point: NSPoint) throws {
        try host.choose(title, at: point)
    }

    func close() {
        host.close()
    }
}
#endif
