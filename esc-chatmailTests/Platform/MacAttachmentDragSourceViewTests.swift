#if os(macOS)
import AppKit
import CoreData
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// The view over an attachment in a Mac chat that lets it be dragged out
/// (`MacAttachmentDragSourceView`, `View.macAttachmentDragSource`): when a press is a click,
/// when it starts a drag and with what, and that a right-click on it still gets the
/// attachment's menu. Mac only, so it runs in `Mac.xctestplan`.
///
/// HONEST SCOPE: the real view is mounted over a stand-in attachment (a button), inside the
/// shared stand-in for the row with its menus (`MacMessageRowStandIn`), in a window that is
/// never shown (`MacOffscreenHost`). It is handed mouse
/// events directly, which is what AppKit does once its hit test has chosen it; the hit test
/// itself is asked which view it chooses. No dragging session is started: `beginSession` is
/// replaced, because a session is the window server's and follows the real pointer. So
/// nothing here shows that a drag leaves the window, what it looks like, or that the Finder
/// takes the promise. Nor that the button under the view stays untouched by a click the view
/// took: events sent through a window that is never shown reached neither the view nor a
/// plain button (measured), so that rests on AppKit giving a press to the one view its hit
/// test chose, and on the view not passing it on. None of it has been seen in the app.
@MainActor
final class MacAttachmentDragSourceViewTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var directory: URL!
    private var harnesses: [Harness] = []

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAttachmentDragSourceViewTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeHarness(_ attachment: Attachment) throws -> Harness {
        let harness = Harness(window: try makeTestHostWindow(), attachment: attachment, directory: directory)
        harnesses.append(harness)
        return harness
    }

    // MARK: - Click or drag

    /// Revert-check: deleting `onClick()` from `mouseUp` makes this fail: a click on an
    /// attachment that has its file would open nothing.
    func testPress_releasedInPlace_isTheAttachmentsClick_andStartsNoDrag() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.pointOnAttachment))
        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.pointOnAttachment))

        XCTAssertEqual(harness.model.clicks, 1)
        XCTAssertEqual(harness.model.sessions.count, 0)
    }

    /// Revert-check: starting the drag at the first `mouseDragged`, without
    /// `AttachmentDragPolicy.startsDrag`, makes this fail: a click with a shaky hand would
    /// drag and open nothing.
    func testPress_thatMovesLessThanTheThreshold_isStillAClick() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()
        let press = harness.pointOnAttachment

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: press))
        source.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: press.x + 3, y: press.y)))
        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: NSPoint(x: press.x + 3, y: press.y)))

        XCTAssertEqual(harness.model.sessions.count, 0)
        XCTAssertEqual(harness.model.clicks, 1)
    }

    /// Revert-check: deleting the `beginSession` call from `mouseDragged` makes the first
    /// assertion fail; deleting `!didStartDrag` from its guard makes it 3; deleting
    /// `didStartDrag = true` makes the click count 1.
    func testPress_thatMovesPastTheThreshold_startsOneDragOfThePromise_andIsNotAClick() throws {
        let harness = try makeHarness(try attachment("dir/Q3 report.pdf", bytes: "report bytes"))
        let source = try harness.dragSource()
        let press = harness.pointOnAttachment

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: press))
        for step in [2, 10, 20, 30] {
            source.mouseDragged(
                with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: press.x + CGFloat(step), y: press.y))
            )
        }
        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: NSPoint(x: press.x + 30, y: press.y)))

        XCTAssertEqual(harness.model.sessions.count, 1)
        XCTAssertEqual(harness.model.clicks, 0)
        let session = try XCTUnwrap(harness.model.sessions.first)
        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(session.event.type, .leftMouseDragged)
        let provider = try XCTUnwrap(session.items.first?.item as? MacAttachmentFilePromiseProvider)
        XCTAssertEqual(provider.fileType, UTType.pdf.identifier)
        XCTAssertEqual(provider.filePromiseProvider(provider, fileNameForType: provider.fileType), "Q3 report.pdf")

        // The promise is of this attachment's file.
        let destination = directory.appendingPathComponent("Dropped.pdf")
        var answers: [Error?] = []
        provider.filePromiseProvider(provider, writePromiseTo: destination) { answers.append($0) }
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers.first ?? nil)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "report bytes")
    }

    /// The icon is drawn where the press was, so it does not jump as the drag starts.
    ///
    /// Revert-check: centering the dragging frame on the view's origin makes this fail.
    func testDrag_drawsItsIconUnderThePress() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()
        let press = harness.pointOnAttachment

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: press))
        source.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: press.x + 10, y: press.y)))

        let frame = try XCTUnwrap(harness.model.sessions.first?.items.first).draggingFrame
        let pressInView = source.convert(press, from: nil)
        XCTAssertEqual(frame.midX, pressInView.x, accuracy: 0.5)
        XCTAssertEqual(frame.midY, pressInView.y, accuracy: 0.5)
        XCTAssertEqual(frame.width, MacAttachmentDragSourceView.dragIconSide)
        XCTAssertEqual(frame.height, MacAttachmentDragSourceView.dragIconSide)
    }

    /// Revert-check: setting `didStartDrag = true` only after `resolveItem()` answered makes
    /// the second assertion fail: dragging an attachment whose file is gone would open Quick
    /// Look when the button came up.
    func testDrag_ofAnAttachmentWhoseFileIsGone_startsNothing_andIsNotAClick() throws {
        let harness = try makeHarness(try attachment("Report.pdf", bytes: nil))
        let source = try harness.dragSource()
        let press = harness.pointOnAttachment

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: press))
        source.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: press.x + 10, y: press.y)))
        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: NSPoint(x: press.x + 10, y: press.y)))

        XCTAssertEqual(harness.model.sessions.count, 0)
        XCTAssertEqual(harness.model.clicks, 0)
    }

    /// Revert-check: passing `releasedInside: true` to `isClick` makes this fail.
    func testPress_releasedOffTheAttachment_isNotAClick() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: harness.pointOnAttachment))
        // Two points off: less than the drag threshold, and outside the view.
        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.pointOnText))

        XCTAssertEqual(harness.model.clicks, 0)
    }

    /// A release with no press before it: the press was on another view.
    ///
    /// Revert-check: deleting `guard pressLocation != nil` from `mouseUp` makes this fail.
    func testRelease_withNoPressOnTheView_isNotAClick() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()

        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: harness.pointOnAttachment))

        XCTAssertEqual(harness.model.clicks, 0)
    }

    /// After a real drag the session takes the release, so `mouseUp` never comes. The next
    /// press must still be a click.
    ///
    /// Revert-check: deleting `didStartDrag = false` from `mouseDown` makes this fail.
    func testAClick_afterADragWhoseReleaseNeverCame_isAClick() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()
        let press = harness.pointOnAttachment

        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: press))
        source.mouseDragged(with: try harness.mouse(.leftMouseDragged, at: NSPoint(x: press.x + 10, y: press.y)))
        source.mouseDown(with: try harness.mouse(.leftMouseDown, at: press))
        source.mouseUp(with: try harness.mouse(.leftMouseUp, at: press))

        XCTAssertEqual(harness.model.sessions.count, 1)
        XCTAssertEqual(harness.model.clicks, 1)
    }

    // MARK: - What the view leaves alone

    /// AppKit gives the left mouse button to the frontmost view under the pointer, and asks
    /// that view for a right-click's menu.
    ///
    /// Revert-check: deleting the `menu(for:)` override from `MacAttachmentDragSourceView`
    /// makes the second assertion fail: the view has no menu of its own.
    func testTheDragSource_isWhatAPressHits_andARightClickOnItGetsTheAttachmentsMenu() throws {
        let harness = try makeHarness(try attachment("Report.pdf"))
        let source = try harness.dragSource()

        XCTAssertTrue(harness.hitView(at: harness.pointOnAttachment) === source)
        let rightClick = try harness.mouse(.rightMouseDown, at: harness.pointOnAttachment)
        XCTAssertEqual(
            harness.entries(of: source.menu(for: rightClick)),
            ["Quick Look:on", "Save Attachment…:on", "---", "Reply:on", "Forward:on"]
        )
        // And beside the attachment, the message's.
        XCTAssertFalse(harness.hitView(at: harness.pointOnText) === source)
        XCTAssertEqual(harness.entries(of: try harness.hostMenu(at: harness.pointOnText)), ["Reply:on", "Forward:on"])
    }

    /// The view is put over the attachment when the row is drawn, and the attachment can lose
    /// its file before the row is drawn again (a missing file's download failing). The view
    /// then takes no press: the click, and a right-click, are the attachment's own view's, with
    /// its retry control. Found in review of PR 408: the view took the click and opened Quick
    /// Look, without the check every attachment button makes.
    ///
    /// The stand-in observes nothing of the attachment, so the view is still mounted after
    /// the state changes, which is the case this pins.
    ///
    /// Revert-check: deleting the `hitTest` override from `MacAttachmentDragSourceView` makes
    /// the assertion after the state change fail, and so does passing `takesMouse: { true }`
    /// in `macAttachmentDragSource`.
    func testTheDragSource_overAnAttachmentThatLostItsFile_takesNoPress_thoughItIsStillThere() throws {
        let attachment = try attachment("Report.pdf")
        let harness = try makeHarness(attachment)
        let source = try harness.dragSource()
        XCTAssertTrue(harness.hitView(at: harness.pointOnAttachment) === source)

        attachment.state = .failed

        XCTAssertTrue(harness.optionalDragSource() === source)
        let hit = try XCTUnwrap(harness.hitView(at: harness.pointOnAttachment), "Nothing takes the press")
        XCTAssertFalse(hit === source)
        // A right-click there is still answered with a menu, by the views behind. Its entries
        // are as the stand-in last drew them, so they are not read here.
        XCTAssertNotNil(try harness.hostMenu(at: harness.pointOnAttachment))
    }

    /// Revert-check: returning `.copy` from `sourceOperationMask(for:)` whatever the context
    /// makes the second fail. Nothing in the app takes an attachment back.
    func testADrag_mayBeCopiedOutsideTheApp_andNowhereInIt() throws {
        let source = try makeHarness(try attachment("Report.pdf")).dragSource()

        XCTAssertEqual(source.sourceOperationMask(for: .outsideApplication), .copy)
        XCTAssertEqual(source.sourceOperationMask(for: .withinApplication), [])
    }

    func testAPressOnTheAttachment_neverMovesTheWindow() throws {
        XCTAssertFalse(try makeHarness(try attachment("Report.pdf")).dragSource().mouseDownCanMoveWindow)
    }

    // MARK: - Where the view is

    /// The view takes the attachment's clicks, so it is there only where a click's whole job
    /// is Quick Look. A failed attachment's retry control must stay reachable.
    ///
    /// Revert-check: deleting `if attachment.isReady` from `macAttachmentDragSource` makes the
    /// loop's assertion fail.
    func testTheDragSource_isOverAnAttachmentOnlyWhileItHasItsFile() throws {
        for state in [Attachment.State.downloaded, .uploaded] {
            let harness = try makeHarness(try attachment("Report.pdf", state: state))
            XCTAssertNotNil(harness.optionalDragSource(), "\(state)")
        }
        for state in [Attachment.State.queued, .failed, .uploading] {
            let harness = try makeHarness(try attachment("Report.pdf", state: state, bytes: nil))
            XCTAssertNil(harness.optionalDragSource(), "\(state)")
            XCTAssertEqual(
                harness.entries(of: try harness.hostMenu(at: harness.pointOnAttachment)),
                ["Quick Look:off", "Save Attachment…:off", "---", "Reply:on", "Forward:on"]
            )
        }
    }
}

// MARK: - Harness

/// What the drag source did.
@MainActor
private final class DragModel: ObservableObject {
    struct Session {
        let items: [NSDraggingItem]
        let event: NSEvent
    }

    var clicks = 0
    var sessions: [Session] = []
}

/// The suite's harness: the shared row stand-in (`MacMessageRowStandIn`) with one attachment,
/// a button as every attachment view is, carrying the real drag source and menu modifiers in
/// the order the app applies them, in the shared off-screen host.
@MainActor
private final class Harness {
    private static let columns = 2

    let model: DragModel
    private let host: MacOffscreenHost

    init(window: NSWindow, attachment: Attachment, directory: URL) {
        let model = DragModel()
        self.model = model
        let cell = MacMessageRowStandInLayout.cell
        host = MacOffscreenHost(
            window: window,
            size: MacMessageRowStandInLayout.size(columns: Self.columns),
            rootView: MacMessageRowStandIn(
                columns: Self.columns,
                onMessageAction: { _ in },
                attachments: {
                    Button {} label: {
                        Color.red.frame(width: cell, height: cell)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .macAttachmentDragSource(attachment: attachment, onClick: { model.clicks += 1 })
                    .macAttachmentExportMenu(
                        attachment: attachment,
                        shownAttachments: [attachment],
                        onQuickLook: {}
                    )
                }
            )
        )
        // SwiftUI builds its AppKit views on a later turn of the run loop. An attachment
        // with no file gets no drag source, so there is nothing to wait long for.
        let source = host.waitForView(MacAttachmentDragSourceView.self, timeout: attachment.isReady ? 5 : 0.3)
        if let source {
            // The app's lookup reads Application Support; the tests' files are elsewhere.
            source.resolveItem = { [directory] in
                AttachmentExportItem(
                    attachment: attachment,
                    resolveURL: { $0.map { directory.appendingPathComponent($0) } }
                )
            }
            source.beginSession = { [model] _, items, event in
                model.sessions.append(DragModel.Session(items: items, event: event))
            }
        }
    }

    var pointOnText: NSPoint {
        MacMessageRowStandInLayout.pointOnText(columns: Self.columns)
    }

    var pointOnAttachment: NSPoint {
        MacMessageRowStandInLayout.pointOnAttachment()
    }

    func optionalDragSource() -> MacAttachmentDragSourceView? {
        host.first(MacAttachmentDragSourceView.self)
    }

    func dragSource() throws -> MacAttachmentDragSourceView {
        try XCTUnwrap(optionalDragSource(), "The drag source was not built")
    }

    func hitView(at point: NSPoint) -> NSView? {
        host.hitView(at: point)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try host.mouse(type, at: point)
    }

    func hostMenu(at point: NSPoint) throws -> NSMenu? {
        try host.menu(at: point)
    }

    func entries(of menu: NSMenu?) -> [String] {
        host.entries(of: menu)
    }

    func close() {
        host.close()
    }
}
#endif
