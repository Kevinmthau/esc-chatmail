#if os(macOS)
import AppKit
import CoreData
import SwiftUI
import WebKit
import XCTest
@testable import esc_chatmail

/// A file dropped on the Mac's chat (`View.macDraftFileDrop`, `MacDraftFileDropView`), and the
/// two views in front of the chat that hand a file drag to it instead of taking it themselves
/// (`MacFileDropForwarder`): the reply field's text view and an email's web view. Mac only, so
/// it runs in `Mac.xctestplan`.
///
/// HONEST SCOPE: the views are mounted in a window that is never shown, and each is handed a
/// drag directly (`FakeDraggingInfo`), which is what AppKit does once it has chosen a view. No
/// file is dragged and no test asks AppKit which view it would choose: that was measured once,
/// through AppKit's private hit test, and is written down in `docs/mac-app-plan.md` ("Files").
/// So these pin what each view does with a drag it is given, not that it is given it, and
/// nothing here has been seen in the app. One term of the drop view's answer is not run here
/// either: that its window has a sheet attached, which would mean presenting one. The rule
/// for it is `DraftFileDropPolicyTests`'; that the view reads `attachedSheet` is not pinned.
@MainActor
final class MacDraftFileDropViewTests: XCTestCase {
    // MARK: - The drop view

    /// Revert-check: returning false from `MacDraftFileDropView.performDragOperation` without
    /// calling `onDropFiles` makes this fail; returning `[]` from `operation(for:)` makes the
    /// first assertion fail.
    func testFileDrag_overTheChat_isACopy_andTheDropHandsOverTheFilesInOrder() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        let files = [URL(fileURLWithPath: "/tmp/One.pdf"), URL(fileURLWithPath: "/tmp/Two.png")]
        let drag = FakeDraggingInfo.files(files, in: harness.window)

        XCTAssertEqual(harness.dropView.draggingEntered(drag), .copy)
        XCTAssertEqual(harness.dropView.draggingUpdated(drag), .copy)
        XCTAssertTrue(harness.dropView.prepareForDragOperation(drag))
        XCTAssertTrue(harness.dropView.performDragOperation(drag))

        XCTAssertEqual(harness.model.drops.map { $0.map(\.path) }, [["/tmp/One.pdf", "/tmp/Two.png"]])
        harness.close()
    }

    /// The drop reports what the chat answered, so a drop the composer refuses slides back.
    ///
    /// Revert-check: returning true from `performDragOperation` whatever `onDropFiles`
    /// answers makes this fail.
    func testDrop_theChatRefuses_isNotTaken() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        harness.model.takesDrops = false
        let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window)

        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertEqual(harness.model.drops.count, 1)
        harness.close()
    }

    /// Revert-check: passing `acceptsFiles: true` in `operation(for:)` whatever the closure
    /// answers makes every assertion fail; dropping the `operation(for:)` guard from
    /// `performDragOperation` makes the last two fail.
    func testFileDrag_whileTheReplyCannotTakeFiles_isRefused_beforeAndAtTheDrop() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        harness.model.accepts = false
        let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window)

        XCTAssertEqual(harness.dropView.draggingEntered(drag), [])
        XCTAssertEqual(harness.dropView.draggingUpdated(drag), [])
        XCTAssertFalse(harness.dropView.prepareForDragOperation(drag))
        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// A send or an import can start between the drag coming in and the drop.
    func testDrop_afterTheReplyStoppedTakingFiles_isRefused() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window)
        XCTAssertEqual(harness.dropView.draggingEntered(drag), .copy)

        harness.model.accepts = false

        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// Revert-check: passing `carriesFiles: true` in `operation(for:)` whatever the
    /// pasteboard holds makes the text drag fail; reading every URL (`options: [:]`) in
    /// `carriesFiles` makes the link fail.
    func testDrag_ofTextOrALink_isNotTheChats() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        let text = FakeDraggingInfo.text("Some words", in: harness.window)
        let link = FakeDraggingInfo(
            pasteboard: FakeDraggingInfo.pasteboard(
                holding: [try XCTUnwrap(NSURL(string: "https://example.com/a.pdf"))]
            ),
            window: harness.window
        )

        XCTAssertEqual(harness.dropView.draggingEntered(text), [])
        XCTAssertFalse(harness.dropView.performDragOperation(text))
        XCTAssertEqual(harness.dropView.draggingEntered(link), [])
        XCTAssertFalse(harness.dropView.performDragOperation(link))
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// Revert-check: passing `sourceAllowsCopy: true` in `operation(for:)` whatever the
    /// source allows makes this fail.
    func testFileDrag_whoseSourceAllowsNoCopy_isRefused() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            sourceOperationMask: [.link]
        )

        XCTAssertEqual(harness.dropView.draggingEntered(drag), [])
        harness.close()
    }

    /// AppKit asks about a drag at every move of the pointer, and what a drag carries is a
    /// question to the pasteboard server. It is asked once for each drag.
    ///
    /// The pasteboard is emptied after the drag came in, which no real drag's is: it is how
    /// a second question would show, by being answered differently.
    ///
    /// Revert-check: passing `Self.carriesFiles(sender.draggingPasteboard)` in place of
    /// `carriesFiles(sender)` in `MacDraftFileDropView.operation(for:)` makes the update's
    /// assertion fail. Returning the kept answer whatever the drag's sequence number makes
    /// the last assertion fail.
    func testFileDrag_isAskedOfThePasteboardOnce_andTheNextDragIsAskedAgain() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        let pasteboard = FakeDraggingInfo.pasteboard(holding: [URL(fileURLWithPath: "/tmp/One.pdf") as NSURL])
        let drag = FakeDraggingInfo(pasteboard: pasteboard, window: harness.window)
        XCTAssertEqual(harness.dropView.draggingEntered(drag), .copy)

        pasteboard.clearContents()
        XCTAssertFalse(MacDraftFileDropView.carriesFiles(pasteboard))

        XCTAssertEqual(harness.dropView.draggingUpdated(drag), .copy)
        // The drop reads the files themselves, whatever was kept, and finds none.
        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertTrue(harness.model.drops.isEmpty)

        let text = FakeDraggingInfo.text("Some words", in: harness.window)
        XCTAssertNotEqual(text.draggingSequenceNumber, drag.draggingSequenceNumber)
        XCTAssertEqual(harness.dropView.draggingEntered(text), [])
        harness.close()
    }

    /// The drop view is behind the whole chat and must take no click from it.
    ///
    /// Revert-check: deleting the `hitTest(_:)` override from `MacDraftFileDropView` makes
    /// this fail.
    func testDropView_takesNoClicks() throws {
        let harness = try Harness(window: try makeTestHostWindow())
        let inside = NSPoint(x: harness.dropView.bounds.midX, y: harness.dropView.bounds.midY)
        XCTAssertTrue(harness.dropView.bounds.contains(inside))

        XCTAssertNil(harness.dropView.hitTest(harness.dropView.convert(inside, to: harness.dropView.superview)))
        harness.close()
    }

    /// Revert-check: deleting `registerForDraggedTypes([.fileURL])` from the initializer
    /// makes this fail. Unregistered, AppKit never offers the view a drag at all.
    func testDropView_isRegisteredForFiles_andFillsTheChat() throws {
        let harness = try Harness(window: try makeTestHostWindow())

        XCTAssertEqual(harness.dropView.registeredDraggedTypes, [.fileURL])
        XCTAssertEqual(harness.dropView.convert(harness.dropView.bounds, to: nil).size, Harness.size)
        harness.close()
    }

    /// Nothing in the app decodes this view, but `init(coder:)` is a required initializer and
    /// must not be a trap in the release build: a decoded view is a drop view like any other.
    ///
    /// HONEST SCOPE: not revert-checked. Putting the `fatalError` back does not fail this
    /// test, it stops the test host. Whether an archive carries the view's registered types
    /// by itself was not measured, so the `registerForDraggedTypes` call in `init(coder:)` is
    /// not pinned by this either.
    func testDropView_decodedFromAnArchive_isRegisteredForFiles_andTakesNoClicks() throws {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: MacDraftFileDropView(frame: NSRect(x: 0, y: 0, width: 40, height: 40)),
            requiringSecureCoding: false
        )
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = false
        let decoded = try XCTUnwrap(
            unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? MacDraftFileDropView
        )

        XCTAssertTrue(decoded.registeredDraggedTypes.contains(.fileURL))
        XCTAssertNil(decoded.hitTest(NSPoint(x: 20, y: 20)))
    }

    // MARK: - Found by the views in front of it

    /// Revert-check: returning the drop view from `dropView(under:at:)` whether or not its
    /// frame holds the point makes the second assertion fail; returning nil for it always
    /// makes the first fail.
    func testDropViewLookup_findsTheChatUnderAPoint_andNothingOutsideIt() throws {
        let harness = try Harness(window: try makeTestHostWindow(), chatSize: CGSize(width: 200, height: 150))
        let frame = harness.dropView.convert(harness.dropView.bounds, to: nil)

        XCTAssertTrue(
            MacDraftFileDropView.dropView(in: harness.window, at: NSPoint(x: frame.midX, y: frame.midY))
                === harness.dropView
        )
        XCTAssertNil(
            MacDraftFileDropView.dropView(in: harness.window, at: NSPoint(x: frame.maxX + 20, y: frame.midY))
        )
        XCTAssertNil(MacDraftFileDropView.dropView(in: nil, at: .zero))
        harness.close()
    }

    // MARK: - The reply field

    /// A text view given a file types its path at the pointer. In a reply the file is
    /// attached instead, and the draft is left as it was.
    ///
    /// Revert-check: deleting the `draggingEntered`, `prepareForDragOperation` and
    /// `performDragOperation` overrides from `MacReplyTextView` makes this fail: the drop is
    /// not handed over and "/tmp/One.pdf" is typed into the draft.
    func testFileDrag_onTheReplyField_goesToTheChat_andTypesNothing() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        let textView = try harness.replyTextView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: textView.convert(NSPoint(x: 5, y: 5), to: nil)
        )

        XCTAssertEqual(textView.draggingEntered(drag), .copy)
        XCTAssertEqual(textView.draggingUpdated(drag), .copy)
        XCTAssertTrue(textView.prepareForDragOperation(drag))
        XCTAssertTrue(textView.performDragOperation(drag))
        textView.concludeDragOperation(drag)

        XCTAssertEqual(harness.model.drops.map { $0.map(\.path) }, [["/tmp/One.pdf"]])
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(harness.model.text, "Hello")
        harness.close()
    }

    /// Revert-check: answering `nil` from `MacFileDropForwarder.draggingEntered` where it
    /// finds no drop view (so the text view takes the drag) makes this fail.
    func testFileDrag_onAReplyFieldWithNoChatBehindIt_isRefused_andTypesNothing() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello", hasDropView: false)
        let textView = try harness.replyTextView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: textView.convert(NSPoint(x: 5, y: 5), to: nil)
        )

        XCTAssertEqual(textView.draggingEntered(drag), [])
        XCTAssertFalse(textView.prepareForDragOperation(drag))
        XCTAssertFalse(textView.performDragOperation(drag))
        textView.concludeDragOperation(drag)

        XCTAssertEqual(textView.string, "Hello")
        harness.close()
    }

    /// Revert-check: refusing where the forwarder answers nil (`?? []` in place of
    /// `?? super.draggingEntered(sender)`, and the same in `performDragOperation`) makes
    /// this fail.
    func testTextDrag_onTheReplyField_isStillTheTextViews() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "")
        let textView = try harness.replyTextView()
        let drag = FakeDraggingInfo.text(
            "Dragged words",
            in: harness.window,
            at: textView.convert(NSPoint(x: 5, y: 5), to: nil)
        )

        XCTAssertNotEqual(textView.draggingEntered(drag), [])
        XCTAssertTrue(textView.prepareForDragOperation(drag))
        XCTAssertTrue(textView.performDragOperation(drag))
        textView.concludeDragOperation(drag)

        XCTAssertEqual(textView.string, "Dragged words")
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// A drag that left is forgotten: the next drag, of text, is the text view's again.
    ///
    /// Revert-check: deleting `end()` from `MacFileDropForwarder.draggingExited` makes this
    /// fail: the text drag's update is answered as the file drag was.
    func testFileDrag_thatLeavesTheField_isForgotten() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "")
        let textView = try harness.replyTextView()
        let at = textView.convert(NSPoint(x: 5, y: 5), to: nil)
        harness.model.accepts = false
        let files = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window, at: at)
        XCTAssertEqual(textView.draggingEntered(files), [])

        textView.draggingExited(files)

        let text = FakeDraggingInfo.text("Dragged words", in: harness.window, at: at)
        XCTAssertNotEqual(textView.draggingUpdated(text), [])
        harness.close()
    }

    // MARK: - An email's web view

    /// Revert-check: deleting the `draggingEntered` and `performDragOperation` overrides from
    /// `LayoutAwareWKWebView` makes this fail: WebKit takes the drop and nothing reaches the
    /// chat.
    func testFileDrag_onAnEmailCard_goesToTheChat() throws {
        let harness = try Harness(window: try makeTestHostWindow(), hasWebView: true)
        let webView = try harness.webView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        )

        XCTAssertEqual(webView.draggingEntered(drag), .copy)
        XCTAssertEqual(webView.draggingUpdated(drag), .copy)
        XCTAssertTrue(webView.prepareForDragOperation(drag))
        XCTAssertTrue(webView.performDragOperation(drag))
        webView.concludeDragOperation(drag)

        XCTAssertEqual(harness.model.drops.map { $0.map(\.path) }, [["/tmp/One.pdf"]])
        harness.close()
    }

    /// The reader's sheet has no chat behind it. A `WKWebView` given the file would load it in
    /// place of the email.
    ///
    /// Revert-check: deleting the drag overrides from `LayoutAwareWKWebView` makes this fail:
    /// WebKit answers the drag with a copy and takes the drop.
    func testFileDrag_onAWebViewWithNoChatBehindIt_isRefused() throws {
        let harness = try Harness(window: try makeTestHostWindow(), hasDropView: false, hasWebView: true)
        let webView = try harness.webView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        )

        XCTAssertEqual(webView.draggingEntered(drag), [])
        XCTAssertEqual(webView.draggingUpdated(drag), [])
        XCTAssertFalse(webView.prepareForDragOperation(drag))
        XCTAssertFalse(webView.performDragOperation(drag))
        webView.concludeDragOperation(drag)
        harness.close()
    }

    /// No drag reaches WebKit, with a chat behind the web view or without one.
    ///
    /// Revert-check: answering with `super`'s where the forwarder answers nil (as
    /// `MacReplyTextView` does) makes this fail.
    func testTextOrLinkDrag_onAWebView_isRefused() throws {
        let harness = try Harness(window: try makeTestHostWindow(), hasWebView: true)
        let webView = try harness.webView()
        let at = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let link = FakeDraggingInfo(
            pasteboard: FakeDraggingInfo.pasteboard(
                holding: [try XCTUnwrap(NSURL(string: "https://example.com/"))]
            ),
            window: harness.window,
            locationInWindow: at
        )

        XCTAssertEqual(webView.draggingEntered(link), [])
        XCTAssertFalse(webView.prepareForDragOperation(link))
        XCTAssertFalse(webView.performDragOperation(link))
        webView.concludeDragOperation(link)
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    // MARK: - Pasted into the reply field

    /// A pasteboard of the test's own for a paste, never the one the user copies to. The
    /// test releases it: it lives in the pasteboard server.
    private func pasteboard(
        files: [URL] = [],
        text: String? = nil,
        image: (type: NSPasteboard.PasteboardType, data: Data)? = nil
    ) -> NSPasteboard {
        var objects: [NSPasteboardWriting] = files.map { $0 as NSURL }
        if let text { objects.append(text as NSString) }
        let pasteboard = FakeDraggingInfo.pasteboard(holding: objects)
        if let image {
            pasteboard.addTypes([image.type], owner: nil)
            pasteboard.setData(image.data, forType: image.type)
        }
        return pasteboard
    }

    private func makePasteDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDraftFileDropViewTests-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])

    /// A text view pastes a copied file as its path. In a reply the file is attached, as one
    /// dropped on the chat is, and the draft is left as it was.
    ///
    /// Revert-check: not handing the files to the chat in the `.attachFiles` case of
    /// `MacReplyTextView.pasteAttachments` makes this fail. HONEST SCOPE: the test calls
    /// `pasteAttachments`, never the paste command, which reads what the user has copied;
    /// that the command asks `pasteAttachments` first is `ReplyFieldPasteSourceTests`' to pin.
    func testPaste_ofCopiedFiles_attachesThem_andTypesNothing() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [URL(fileURLWithPath: "/tmp/One.pdf"), URL(fileURLWithPath: "/tmp/Two.png")]
        // A file copied in the Finder carries its name as text too.
        let copied = pasteboard(files: files, text: "One.pdf")
        defer { copied.releaseGlobally() }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: copied, imageDirectory: directory, refusals: refusals)

        XCTAssertTrue(textView.pasteAttachments())

        XCTAssertEqual(harness.model.drops, [files])
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(refusals.count, 0)
        harness.close()
    }

    /// While a send owns the draft, or an import is running, the reply takes no file. The
    /// paste is refused with a beep and is still not the text view's: it would type the path.
    ///
    /// Revert-check: returning false from `MacReplyTextView.pasteAttachments` where the chat
    /// refuses the files makes this fail.
    func testPaste_ofCopiedFiles_theChatCannotTake_isRefused_andStillTypesNothing() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        harness.model.accepts = false
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = pasteboard(files: [URL(fileURLWithPath: "/tmp/One.pdf")])
        defer { copied.releaseGlobally() }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: copied, imageDirectory: directory, refusals: refusals)

        XCTAssertTrue(textView.pasteAttachments())

        XCTAssertTrue(harness.model.drops.isEmpty)
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(refusals.count, 1)
        harness.close()
    }

    /// Revert-check: answering `nil != true` as taken (dropping the `!= true` from the
    /// `.attachFiles` case) makes this fail: with no chat behind the field the paste would
    /// do nothing and say nothing.
    func testPaste_ofCopiedFiles_withNoChatBehindTheField_isRefused() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello", hasDropView: false)
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = pasteboard(files: [URL(fileURLWithPath: "/tmp/One.pdf")])
        defer { copied.releaseGlobally() }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: copied, imageDirectory: directory, refusals: refusals)

        XCTAssertTrue(textView.pasteAttachments())

        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(refusals.count, 1)
        harness.close()
    }

    /// Words are the text view's to paste, with a picture beside them or not: cells copied
    /// from a spreadsheet carry both.
    ///
    /// Revert-check: asking about the image before the text in
    /// `ReplyFieldPastePolicy.action` makes the second assertion fail.
    func testPaste_ofText_isLeftToTheTextView() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let refusals = PasteRefusals()
        let words = pasteboard(text: "Some words")
        let wordsAndPicture = pasteboard(text: "A1\tB1", image: (.png, Self.pngBytes))
        defer {
            words.releaseGlobally()
            wordsAndPicture.releaseGlobally()
        }

        let textView = try harness.replyTextView(pastingFrom: words, imageDirectory: directory, refusals: refusals)
        XCTAssertFalse(textView.pasteAttachments())
        textView.pasteboardForPaste = { wordsAndPicture }
        XCTAssertFalse(textView.pasteAttachments())

        XCTAssertTrue(harness.model.drops.isEmpty)
        XCTAssertTrue(harness.model.pastedImageFiles.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(refusals.count, 0)
        harness.close()
    }

    /// A screenshot taken to the clipboard is bytes with no file. They are written to a file
    /// of the app's own, which the chat is handed and removes once it has imported it.
    ///
    /// Revert-check: deleting the `receivePastedImageFile` call from
    /// `MacReplyTextView.attachPastedImage` makes this fail.
    func testPaste_ofACopiedImage_writesItToAFile_andHandsTheChatThatFile() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = pasteboard(image: (.png, Self.pngBytes))
        defer { copied.releaseGlobally() }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: copied, imageDirectory: directory, refusals: refusals)

        XCTAssertTrue(textView.pasteAttachments())

        let file = try XCTUnwrap(harness.model.pastedImageFiles.first)
        XCTAssertEqual(harness.model.pastedImageFiles.count, 1)
        XCTAssertEqual(harness.model.pastedImageFileExisted, [true])
        XCTAssertEqual(file.lastPathComponent, "Pasted Image.png")
        XCTAssertEqual(try Data(contentsOf: file), Self.pngBytes)
        XCTAssertTrue(file.path.hasPrefix(directory.path))
        XCTAssertTrue(harness.model.drops.isEmpty)
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(refusals.count, 0)
        harness.close()
    }

    /// Asked before the bytes are written, so a refusal leaves no file.
    ///
    /// HONEST SCOPE: this pins the outcome, a refusal and no file left. With
    /// `chatDropView.acceptsPastedImage` deleted from the guard in
    /// `MacReplyTextView.attachPastedImage` it still passes, because the file is then
    /// written, refused and removed; it does not show that nothing was written meanwhile.
    func testPaste_ofACopiedImage_theChatCannotTake_isRefused_andLeavesNoFile() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        harness.model.accepts = false
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = pasteboard(image: (.tiff, Self.pngBytes))
        defer { copied.releaseGlobally() }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: copied, imageDirectory: directory, refusals: refusals)

        XCTAssertTrue(textView.pasteAttachments())

        XCTAssertTrue(harness.model.pastedImageFiles.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(refusals.count, 1)
        harness.close()
    }

    /// The chat can still say no once it has the file: a second paste arrived first. The
    /// file is then the field's to remove.
    ///
    /// Revert-check: deleting `PastedImageFile.remove([file])` from
    /// `MacReplyTextView.attachPastedImage` makes this fail: the image stays in the
    /// temporary directory with nothing left to remove it.
    func testPaste_ofACopiedImage_theChatHandsBack_removesItsFile() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        harness.model.takesDrops = false
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = pasteboard(image: (.png, Self.pngBytes))
        defer { copied.releaseGlobally() }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: copied, imageDirectory: directory, refusals: refusals)

        XCTAssertTrue(textView.pasteAttachments())

        XCTAssertEqual(harness.model.pastedImageFileExisted, [true])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(refusals.count, 1)
        harness.close()
    }

    /// A text view enables Paste for what it reads itself, and this one reads no images.
    ///
    /// Revert-check: answering false from `MacReplyTextView.enablesPasteItself` makes the
    /// first assertion fail: with only an image copied, Paste is disabled and Command-V
    /// never reaches the field.
    ///
    /// HONEST SCOPE: the field's own answer is asked (`enablesPasteItself`), not
    /// `validateUserInterfaceItem`. Where the field has none, the text view answers from the
    /// pasteboard the user copies to, and a test must not depend on that; that the override
    /// asks the field first is `ReplyFieldPasteSourceTests`' to pin.
    func testPasteCommand_isEnabledByTheFieldForACopiedImage_andLeftToTheTextViewOtherwise() throws {
        let harness = try Harness(window: try makeTestHostWindow(), text: "Hello")
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = pasteboard(image: (.png, Self.pngBytes))
        let words = pasteboard(text: "Some words")
        defer {
            image.releaseGlobally()
            words.releaseGlobally()
        }
        let refusals = PasteRefusals()
        let textView = try harness.replyTextView(pastingFrom: image, imageDirectory: directory, refusals: refusals)
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

        XCTAssertTrue(textView.enablesPasteItself(pasteItem))
        XCTAssertFalse(textView.enablesPasteItself(copyItem))
        textView.pasteboardForPaste = { words }
        XCTAssertFalse(textView.enablesPasteItself(pasteItem))
        harness.close()
    }

    /// What the field reads off a pasteboard, which decides both what Paste does and whether
    /// the field answers for the command itself.
    ///
    /// Revert-check: dropping `.tiff` from `MacReplyTextView.pastedImageTypes` makes the
    /// TIFF assertion fail: a selection copied in Preview would paste as nothing.
    func testPasteAction_isReadFromWhatThePasteboardHas() {
        let files = pasteboard(files: [URL(fileURLWithPath: "/tmp/One.pdf")], text: "One.pdf")
        let words = pasteboard(text: "Some words")
        let png = pasteboard(image: (.png, Self.pngBytes))
        let tiff = pasteboard(image: (.tiff, Self.pngBytes))
        let jpeg = pasteboard(image: (NSPasteboard.PasteboardType("public.jpeg"), Self.pngBytes))
        let nothing = pasteboard()
        defer { [files, words, png, tiff, jpeg, nothing].forEach { $0.releaseGlobally() } }

        XCTAssertEqual(MacReplyTextView.pasteAction(for: files), .attachFiles)
        XCTAssertEqual(MacReplyTextView.pasteAction(for: words), .pasteAsText)
        XCTAssertEqual(MacReplyTextView.pasteAction(for: png), .attachImage)
        XCTAssertEqual(MacReplyTextView.pasteAction(for: tiff), .attachImage)
        XCTAssertEqual(MacReplyTextView.pasteAction(for: jpeg), .attachImage)
        XCTAssertEqual(MacReplyTextView.pasteAction(for: nothing), .pasteAsText)
    }

    /// Whoever imports a request removes the files the app wrote only to carry it. A request
    /// with nothing to import has no import to end, so its files go as it is taken.
    ///
    /// HONEST SCOPE: as for the picker's other tests here, nothing is imported: an import
    /// would write to this host's attachment folder, which is the real app's. That a
    /// request's files are also removed when its import ends is `ReplyFieldPasteSourceTests`'
    /// to pin.
    ///
    /// Revert-check: deleting `PastedImageFile.remove(drop.temporaryFileURLs)` from the
    /// `guard !drop.fileURLs.isEmpty` in `AttachmentPicker.importDroppedFiles` makes this
    /// fail.
    func testPicker_takingARequestWithNothingToImport_removesItsTemporaryFiles() async throws {
        let directory = try makePasteDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try PastedImageFile.write(Self.pngBytes, fileExtension: "png", in: directory)
        let model = PickerModel()
        let harness = PickerHarness(window: try makeTestHostWindow(), model: model)
        defer { harness.close() }

        model.fileDrop = DraftFileDrop(fileURLs: [], unsupportedFilenames: [], temporaryFileURLs: [file])

        try await harness.waitUntil { model.fileDrop == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // MARK: - The picker and a pending drop

    /// A drop the composer took is the picker's to import. One that reaches the picker while
    /// an import runs waits for that import to end; it is not cleared and forgotten, which
    /// is what the picker did with it before: the files had left the user's pointer and
    /// nothing was attached or said.
    ///
    /// HONEST SCOPE: the drop here holds no files, so taking it imports nothing: an import
    /// would write to this host's attachment folder, which is the real app's, and a drop's
    /// alert would be presented on the test's window. What is pinned is when the picker
    /// takes the request, seen by the request being cleared.
    ///
    /// Revert-check: clearing the request above the guard in
    /// `AttachmentPicker.importPendingFileDropIfIdle` makes the first assertion fail;
    /// deleting the `.onChange(of: isProcessing)` from `AttachmentPicker.body` makes the
    /// wait fail.
    func testPicker_givenADropDuringAnImport_keepsIt_andTakesItWhenTheImportEnds() async throws {
        let model = PickerModel()
        let harness = PickerHarness(window: try makeTestHostWindow(), model: model)
        defer { harness.close() }
        let drop = DraftFileDrop(fileURLs: [], unsupportedFilenames: [])

        model.isProcessing = true
        model.fileDrop = drop
        harness.settle()
        XCTAssertEqual(model.fileDrop, drop)

        model.isProcessing = false
        try await harness.waitUntil { model.fileDrop == nil }
    }

    /// Revert-check: deleting the `.onChange(of: fileDrop.wrappedValue…)` from
    /// `AttachmentPicker.body` makes this fail.
    func testPicker_givenADropWhileIdle_takesIt() async throws {
        let model = PickerModel()
        let harness = PickerHarness(window: try makeTestHostWindow(), model: model)
        defer { harness.close() }

        model.fileDrop = DraftFileDrop(fileURLs: [], unsupportedFilenames: [])

        try await harness.waitUntil { model.fileDrop == nil }
    }

    /// A drop taken while no picker was on screen is still the composer's only copy of it,
    /// and the composer takes no other until it is gone.
    ///
    /// Revert-check: dropping `initial: true` from the picker's `onChange` makes this fail.
    func testPicker_comingOnScreenWithADropPending_takesIt() async throws {
        let model = PickerModel()
        model.fileDrop = DraftFileDrop(fileURLs: [], unsupportedFilenames: [])
        let harness = PickerHarness(window: try makeTestHostWindow(), model: model)
        defer { harness.close() }

        try await harness.waitUntil { model.fileDrop == nil }
    }

    // MARK: - The stand-in drag

    /// A named pasteboard is the pasteboard server's and outlives the test that made it. The
    /// stand-in drag releases its own as it goes.
    ///
    /// Revert-check: deleting the `deinit` from `FakeDraggingInfo` makes the second
    /// assertion fail.
    func testFakeDrag_releasesItsPasteboard_whenItIsGone() {
        var name: NSPasteboard.Name?
        autoreleasepool {
            let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: nil)
            name = drag.draggingPasteboard.name
            XCTAssertTrue(MacDraftFileDropView.carriesFiles(NSPasteboard(name: drag.draggingPasteboard.name)))
        }

        let after = NSPasteboard(name: name!)
        XCTAssertFalse(MacDraftFileDropView.carriesFiles(after))
        after.releaseGlobally()
    }

    // MARK: - The import of a dropped file

    /// Why a drop's import does not ask for a security scope. In the Mac's sandbox a file URL
    /// that came from no picker opens none, so the pickers' rule refuses it before reading
    /// anything; told a scope is only taken if offered, the import goes on to read the file.
    ///
    /// The file is larger than a draft may hold, so the import that goes on stops at its size
    /// check and neither case writes anything: this host's attachment folder is the real
    /// app's.
    ///
    /// Revert-check: making `SecurityScope.ifOffered.allowsReading` answer
    /// `didStartAccessing` makes the second import report "could not be read" and this fail.
    func testImport_ofAFileWithNoSecurityScope_isRefusedForAPicker_andReadForADrop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDraftFileDropViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Huge.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        // Sparse: 26 MB of size and no bytes on disk.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DraftAttachmentImport.maximumTotalBytes) + 1024 * 1024)
        try handle.close()
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()

        var failuresByScope: [[String]] = []
        for scope in [DocumentAttachmentImporter.SecurityScope.required, .ifOffered] {
            var operation: Task<Void, Never>?
            var failures: [String] = []
            var attachments: [Attachment] = []
            DocumentAttachmentImporter(
                attachments: Binding(get: { attachments }, set: { attachments = $0 }),
                viewContext: context,
                onProcessingChanged: { _ in },
                onOperationChanged: { if let started = $0 { operation = started } },
                onImportFailures: { failures = $0 },
                registry: AttachmentAccountWorkRegistry(),
                securityScope: scope
            )
            .importDocuments(at: [url])
            let started = try XCTUnwrap(operation, "The import did not start")
            await started.value
            XCTAssertTrue(attachments.isEmpty)
            failuresByScope.append(failures)
        }

        XCTAssertEqual(
            failuresByScope.first,
            [DraftAttachmentImport.ImportError.unreadable(filename: "Huge.pdf").localizedDescription]
        )
        XCTAssertEqual(failuresByScope.last?.count, 1)
        XCTAssertTrue(
            failuresByScope.last?.first?.contains("would exceed the 25 MB") == true,
            "\(failuresByScope)"
        )
    }
}

// MARK: - Harness

private final class PickerModel: ObservableObject {
    @Published var attachments: [Attachment] = []
    @Published var isProcessing = false
    @Published var fileDrop: DraftFileDrop?
}

/// The Mac composer's attachment picker, with a composer's bindings.
private struct PickerStandIn: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        AttachmentPicker(
            attachments: $model.attachments,
            isProcessing: $model.isProcessing,
            style: .plusMenu(diameter: 28),
            fileDrop: $model.fileDrop
        )
    }
}

@MainActor
private final class PickerHarness {
    private let host: MacOffscreenHost

    init(window: NSWindow, model: PickerModel) {
        host = MacOffscreenHost(
            window: window,
            size: CGSize(width: 100, height: 100),
            rootView: PickerStandIn(model: model)
        )
        settle()
    }

    /// Lets SwiftUI finish its update and run the `onChange` actions it owes.
    func settle() {
        host.settle()
    }

    func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("The condition was not met in \(timeout) s")
            }
            host.hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    func close() {
        host.close()
    }
}

/// How many pastes the reply field refused, where the app beeps.
private final class PasteRefusals {
    var count = 0
}

private final class DropModel: ObservableObject {
    var text: String
    var accepts = true
    var takesDrops = true
    var drops: [[URL]] = []
    /// The files of pasted images the chat was handed, and whether each was on disk then.
    var pastedImageFiles: [URL] = []
    var pastedImageFileExisted: [Bool] = []

    init(text: String) {
        self.text = text
    }
}

private struct StandInWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> LayoutAwareWKWebView {
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // As a preview card's is.
        webView.makeNonInteractive()
        return webView
    }

    func updateNSView(_ webView: LayoutAwareWKWebView, context: Context) {}
}

/// A stand-in for the chat column: something in front (a web view, the real reply field) and
/// the real drop view behind, applied with the modifier `ChatView` uses.
private struct ChatStandIn: View {
    let model: DropModel
    let chatSize: CGSize
    let hasDropView: Bool
    let hasWebView: Bool

    var body: some View {
        let chat = VStack(spacing: 0) {
            if hasWebView {
                StandInWebView().frame(height: 60)
            }
            Spacer(minLength: 0)
            MacReplyTextField(
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                fontSize: 13,
                maximumLineCount: 5,
                focusBridge: ReplyFieldFocusBridge(),
                canSend: { _ in true },
                onSend: {},
                onCancel: {}
            )
        }
        .frame(width: chatSize.width, height: chatSize.height)

        if hasDropView {
            chat.macDraftFileDrop(
                acceptsFiles: { model.accepts },
                onDropFiles: { urls in
                    model.drops.append(urls)
                    return model.takesDrops
                },
                onPasteImageFile: { file in
                    model.pastedImageFiles.append(file)
                    model.pastedImageFileExisted.append(FileManager.default.fileExists(atPath: file.path))
                    return model.takesDrops
                }
            )
        } else {
            chat
        }
    }
}

@MainActor
private final class Harness {
    nonisolated static let size = CGSize(width: 400, height: 300)

    let model: DropModel
    private let host: MacOffscreenHost
    private let foundDropView: MacDraftFileDropView?

    init(
        window: NSWindow,
        text: String = "",
        chatSize: CGSize = Harness.size,
        hasDropView: Bool = true,
        hasWebView: Bool = false
    ) throws {
        let model = DropModel(text: text)
        self.model = model
        host = MacOffscreenHost(
            window: window,
            size: Self.size,
            rootView: ChatStandIn(
                model: model,
                chatSize: chatSize,
                hasDropView: hasDropView,
                hasWebView: hasWebView
            )
        )
        // SwiftUI builds its AppKit views on a later turn of the run loop.
        host.waitForView(MacReplyTextView.self)
        foundDropView = host.first(MacDraftFileDropView.self)
        if hasDropView {
            _ = try XCTUnwrap(foundDropView, "The drop view was not built")
        } else {
            XCTAssertNil(foundDropView)
        }
    }

    /// The window the chat is in, for the stand-in drags.
    var window: NSWindow {
        host.window
    }

    var dropView: MacDraftFileDropView {
        // Checked in `init` wherever a test asked for one.
        foundDropView!
    }

    func replyTextView() throws -> MacReplyTextView {
        try XCTUnwrap(host.first(MacReplyTextView.self), "The field's text view was not built")
    }

    /// The reply field's text view, set to paste from `pasteboard` and never from what the
    /// user has copied, to write a pasted image under `imageDirectory`, and to count its
    /// refusals where the app would beep.
    func replyTextView(
        pastingFrom pasteboard: NSPasteboard,
        imageDirectory: URL,
        refusals: PasteRefusals
    ) throws -> MacReplyTextView {
        let textView = try replyTextView()
        textView.pasteboardForPaste = { pasteboard }
        textView.pastedImageDirectory = { imageDirectory }
        textView.refusePaste = { refusals.count += 1 }
        return textView
    }

    func webView() throws -> LayoutAwareWKWebView {
        try XCTUnwrap(host.first(LayoutAwareWKWebView.self), "The web view was not built")
    }

    func close() {
        host.close()
    }
}
#endif
