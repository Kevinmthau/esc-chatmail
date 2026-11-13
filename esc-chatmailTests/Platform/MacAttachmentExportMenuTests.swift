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
/// is `MacEnclosingMessageMenuSourceTests`'. The save panel is a stand-in. None of it has
/// been seen in the app.
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

    /// An attachment whose file, where it has one, is `<its id>.<ext>` in the temporary
    /// directory.
    private func attachment(
        _ filename: String,
        state: Attachment.State = .downloaded,
        bytes: String? = "bytes"
    ) throws -> Attachment {
        let id = "local_\(UUID().uuidString)"
        let attachment = AttachmentBuilder().withId(id).withFilename(filename).build(in: context)
        attachment.state = state
        let stored = "\(id).\((filename as NSString).pathExtension)"
        attachment.localURL = stored
        if let bytes {
            try Data(bytes.utf8).write(to: directory.appendingPathComponent(stored))
        }
        return attachment
    }

    private func makeHarness(_ attachments: [Attachment], inAMessageRow: Bool = true) -> Harness {
        let harness = Harness(attachments: attachments, directory: directory, inAMessageRow: inAMessageRow)
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
        let harness = makeHarness([try attachment("Report.pdf")])

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:on", "Save Attachment…:on", "---", "Reply:on", "Forward:on"]
        )
        XCTAssertEqual(try harness.menuEntries(at: harness.pointOnText), ["Reply:on", "Forward:on"])
    }

    /// The entries handed down are the row's own, and choosing one does what it does in the
    /// row's menu.
    ///
    /// Revert-check: deleting the `if let messageMenu` block from
    /// `MacAttachmentExportMenu.body` makes this fail: the attachment's menu has no Reply.
    func testReply_chosenFromAnAttachmentsMenu_isTheMessagesReply() throws {
        let harness = makeHarness([try attachment("Beach.jpg"), try attachment("Tickets.pdf")])

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
        let harness = makeHarness([try attachment("Report.pdf")], inAMessageRow: false)

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:on", "Save Attachment…:on"]
        )
    }

    /// Revert-check: deleting `.disabled(!entry.isEnabled)` makes this fail.
    func testMenu_ofAnAttachmentStillDownloading_hasItsEntriesDisabled() throws {
        let harness = makeHarness([try attachment("Report.pdf", state: .queued, bytes: nil)])

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:off", "Save Attachment…:off", "---", "Reply:on", "Forward:on"]
        )
    }

    /// Revert-check: passing `shownCount: 1` to `AttachmentExportPolicy.menu` makes the first
    /// assertion fail; passing `readyCount: 0` makes Save All read as off.
    func testMenu_whereTheMessageShowsSeveral_addsSaveAll_onEachOfThem() throws {
        let harness = makeHarness([
            try attachment("Beach.jpg"),
            try attachment("Loading.png", state: .queued, bytes: nil)
        ])

        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(0)),
            ["Quick Look:on", "Save Attachment…:on", "Save All Attachments…:on", "---", "Reply:on", "Forward:on"]
        )
        XCTAssertEqual(
            try harness.menuEntries(at: harness.pointOnAttachment(1)),
            ["Quick Look:off", "Save Attachment…:off", "Save All Attachments…:on", "---", "Reply:on", "Forward:on"]
        )
    }

    // MARK: - What the entries do

    /// Revert-check: calling `resolveItem` with `shownAttachments.first` in place of
    /// `attachment` in the `.save` case makes this fail: the second attachment's menu saves
    /// the first.
    func testSaveAttachment_savesTheAttachmentThatWasClicked_underItsName() async throws {
        let harness = makeHarness([
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
        let harness = makeHarness([try attachment("Report.pdf", bytes: nil)])

        try harness.choose("Save Attachment…", at: harness.pointOnAttachment(0))
        try await waitUntil { !harness.panels.alerts.isEmpty }

        XCTAssertEqual(harness.panels.offeredFilenames, [])
        XCTAssertEqual(harness.panels.alerts, ["Attachment Not Saved|Report.pdf is no longer on this Mac."])
    }

    /// Revert-check: passing `[attachment]` in place of `shownAttachments` in the `.saveAll`
    /// case makes this fail.
    func testSaveAll_savesEveryAttachmentWithAFile_whicheverWasClicked() async throws {
        let harness = makeHarness([
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
        let harness = makeHarness(attachments)

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
}

/// A message's row as far as menus go: text above, its attachments in a line below, and the
/// row's own menu around both, with its entries handed down as `ChatMessagesView` hands its
/// own. With `inAMessageRow` false, the attachments alone, with no menu around them.
private struct RowStandIn: View {
    static let cell: CGFloat = 100

    let attachments: [Attachment]
    let panels: MenuPanels
    let exporter: MacAttachmentExporter
    let directory: URL
    let inAMessageRow: Bool

    var body: some View {
        if inAMessageRow {
            content
                .contentShape(Rectangle())
                .macEnclosingMessageMenu { messageEntries }
                .contextMenu { messageEntries } preview: {
                    Text("Preview")
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var messageEntries: some View {
        Button("Reply") { panels.messageActions.append("Reply") }
        Button("Forward") { panels.messageActions.append("Forward") }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The message's text")
                .frame(width: Self.cell * 3, height: Self.cell)
            HStack(spacing: 0) {
                ForEach(attachments, id: \.objectID) { attachment in
                    Color.red
                        .frame(width: Self.cell, height: Self.cell)
                        .modifier(
                            MacAttachmentExportMenu(
                                attachment: attachment,
                                shownAttachments: attachments,
                                onQuickLook: { panels.quickLooked.append(attachment.objectID) },
                                exporter: exporter,
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
            .frame(width: Self.cell * 3, height: Self.cell, alignment: .leading)
        }
    }
}

@MainActor
private final class Harness {
    let panels = MenuPanels()
    private let window: NSWindow
    private let host: NSHostingView<RowStandIn>

    init(attachments: [Attachment], directory: URL, inAMessageRow: Bool) {
        let size = CGSize(width: RowStandIn.cell * 3, height: RowStandIn.cell * 2)
        window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(
            rootView: RowStandIn(
                attachments: attachments,
                panels: panels,
                exporter: panels.makeExporter(),
                directory: directory,
                inAMessageRow: inAMessageRow
            )
        )
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // SwiftUI finishes its first update on a later turn of the run loop.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
    }

    /// Window coordinates, y up: the text is the upper half and the attachments the lower.
    var pointOnText: NSPoint {
        NSPoint(x: RowStandIn.cell * 1.5, y: RowStandIn.cell * 1.5)
    }

    func pointOnAttachment(_ index: Int) -> NSPoint {
        NSPoint(x: RowStandIn.cell * (CGFloat(index) + 0.5), y: RowStandIn.cell * 0.5)
    }

    /// The menu AppKit would open for a right-click at `point`.
    func menu(at point: NSPoint) throws -> NSMenu {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        return try XCTUnwrap(host.menu(for: event), "No menu at \(point)")
    }

    func menuEntries(at point: NSPoint) throws -> [String] {
        let menu = try menu(at: point)
        menu.update()
        return menu.items.map {
            $0.isSeparatorItem ? "---" : "\($0.title):\($0.isEnabled ? "on" : "off")"
        }
    }

    /// Chooses the entry titled `title`, as a click on it would.
    func choose(_ title: String, at point: NSPoint) throws {
        let menu = try menu(at: point)
        let index = menu.indexOfItem(withTitle: title)
        XCTAssertGreaterThanOrEqual(index, 0, "No \"\(title)\" in \(menu.items.map(\.title))")
        guard index >= 0 else { return }
        menu.performActionForItem(at: index)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
#endif
