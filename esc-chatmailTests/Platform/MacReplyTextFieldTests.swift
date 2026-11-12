#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The Mac's reply field with its real text view (`MacReplyTextField`,
/// `MacReplyTextFieldCoordinator`): what Return, Shift-Return and Escape do when the text
/// system hands them over, how the text reaches the composer, the field's height, and its
/// focus. Mac only, so it runs in `Mac.xctestplan`.
///
/// HONEST SCOPE: the field is mounted in a window that is never shown and never key, and its
/// commands are given to the text view directly (`doCommand(by:)`), which is where the text
/// system delivers a key once an input method has let it through. No key is pressed, and no
/// input method runs: marked text is set by hand. So this pins what the field does with a
/// command, not that a real input method keeps the Return that confirms a word to itself; that
/// is checked in the app, with Japanese input (`docs/mac-imessage-ui-plan.md`, "PR 5 as
/// built").
@MainActor
final class MacReplyTextFieldTests: XCTestCase {
    // MARK: - Return

    /// Revert-check: deleting the `field.onSend()` call from the coordinator's `.send` case
    /// makes this fail.
    func testReturn_withText_sendsOnce_andLeavesTheTextToTheComposer() async throws {
        let harness = try await Harness(text: "Hello")

        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(harness.model.sendCount, 1)
        // The field adds no line of its own and does not clear itself: the composer empties
        // the draft when it takes the send.
        XCTAssertEqual(harness.textView.string, "Hello")
        harness.close()
    }

    /// Return asks about the text in the field now, and the composer is given that text
    /// before it is asked to send: its copy may not have caught up with the last key.
    ///
    /// Revert-check: deleting the `field.text = textView.string` assignment from the `.send`
    /// case makes the last assertion fail; passing `field.text` to `field.canSend` instead
    /// of `textView.string` makes the first fail.
    func testReturn_asksAboutAndSendsTheTextInTheFieldNow() async throws {
        let harness = try await Harness(text: "")
        // The view holds text the binding has not been given: the delegate is taken away
        // while it is typed, as if the change had not reached the composer yet.
        let delegate = harness.textView.delegate
        harness.textView.delegate = nil
        harness.textView.string = "Typed a moment ago"
        harness.textView.delegate = delegate
        XCTAssertEqual(harness.model.text, "")

        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(harness.model.textAskedAbout, ["Typed a moment ago"])
        XCTAssertEqual(harness.model.sendCount, 1)
        XCTAssertEqual(harness.model.textAtSend, ["Typed a moment ago"])
        harness.close()
    }

    /// Revert-check: making the coordinator pass `canSend: true` whatever the field says
    /// makes this fail.
    func testReturn_whenTheComposerCannotSend_sendsNothingAndAddsNoLine() async throws {
        let harness = try await Harness(text: "Waiting on an attachment", canSend: false)

        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(harness.model.sendCount, 0)
        XCTAssertEqual(harness.textView.string, "Waiting on an attachment")
        harness.close()
    }

    /// Revert-check: making `MacReplyTextFieldCoordinator` ignore `key.isShiftDown` (passing
    /// `isShiftDown: false`) makes this fail: Shift-Return sends.
    func testShiftReturn_addsALineAndDoesNotSend() async throws {
        let harness = try await Harness(
            text: "First line",
            key: MacReplyKeyEvent(isShiftDown: true, isRepeat: false)
        )
        harness.textView.setSelectedRange(NSRange(location: 10, length: 0))

        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(harness.model.sendCount, 0)
        XCTAssertEqual(harness.textView.string, "First line\n")
        XCTAssertEqual(harness.model.text, "First line\n")
        harness.close()
    }

    /// Revert-check: passing `isKeyRepeat: false` whatever the key says makes this fail.
    func testHeldReturn_doesNotSend() async throws {
        let harness = try await Harness(
            text: "Hello",
            key: MacReplyKeyEvent(isShiftDown: false, isRepeat: true)
        )

        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(harness.model.sendCount, 0)
        harness.close()
    }

    /// Control-Return adds a plain newline, not the U+2028 a text view inserts for it.
    ///
    /// Revert-check: returning false from `textView(_:doCommandBy:)` for `insertLineBreak:`
    /// (dropping the case from `ReplyFieldKeyPolicy.Command`) makes this fail.
    func testControlReturn_addsAPlainNewline() async throws {
        let harness = try await Harness(text: "A")
        harness.textView.setSelectedRange(NSRange(location: 1, length: 0))

        harness.textView.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))

        XCTAssertEqual(harness.model.sendCount, 0)
        XCTAssertEqual(harness.textView.string, "A\n")
        harness.close()
    }

    /// The Return that confirms an input method's word: if it reaches the field as a command,
    /// it commits the word. It does not send and it adds no line.
    ///
    /// Revert-check: passing `hasMarkedText: false` whatever the view says makes this fail:
    /// the reply is sent with the word still being composed.
    func testReturn_overMarkedText_commitsItAndDoesNotSend() async throws {
        let harness = try await Harness(text: "")
        try harness.compose("にほん")

        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(harness.model.sendCount, 0)
        XCTAssertFalse(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.string, "にほん")
        harness.close()
    }

    // MARK: - A word an input method is still composing

    /// The composer replaces its text while a word is being composed: a send made with the
    /// arrow empties it, a failed reply handed back fills it. The composer's text wins. Left
    /// in place, the view kept all it showed and gave it back to the composer at the next
    /// change: the mail just sent was a draft again, one Return from going out twice.
    ///
    /// Revert-check: putting `guard !textView.hasMarkedText() else { return }` back in place
    /// of the marked-text branch of `MacReplyTextFieldCoordinator.applyTextFromComposer`
    /// makes this fail: the view keeps "Hello にほん".
    func testComposerReplacingItsText_whileAWordIsBeingComposed_replacesWhatTheFieldShows() async throws {
        let harness = try await Harness(text: "Hello ")
        try harness.compose("にほん")

        harness.model.text = ""
        await harness.waitUntil { harness.textView.string.isEmpty }

        XCTAssertEqual(harness.textView.string, "")
        XCTAssertFalse(harness.textView.hasMarkedText())
        // What the view reports next is what was typed next, and nothing of what was sent.
        harness.textView.insertText("Next", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.model.text, "Next")
        harness.close()
    }

    /// While a word is being composed the view is ahead of the composer by that word, and an
    /// update for any other reason must not take the composition away.
    ///
    /// Revert-check: deleting `guard composerText != composerTextKnownToField else { return }`
    /// from `applyTextFromComposer` makes this fail: the update replaces the view's text with
    /// the composer's "Hello " and the word is gone.
    func testUpdateForAnotherReason_whileAWordIsBeingComposed_leavesTheComposition() async throws {
        let harness = try await Harness(text: "Hello ")
        try harness.compose("にほん")

        let evaluations = harness.model.bodyEvaluations
        harness.model.unrelated += 1
        await harness.waitUntil { harness.model.bodyEvaluations > evaluations }
        await harness.nextMainQueueTurn()

        XCTAssertEqual(harness.textView.string, "Hello にほん")
        XCTAssertTrue(harness.textView.hasMarkedText())
        harness.close()
    }

    /// The send arrow asks this before it sends: a click on it does not end a composition,
    /// and the composer's copy lacks the word being composed, so the reply went without it.
    ///
    /// Revert-check: dropping the `commitPendingInput:` argument from the coordinator's
    /// `bridge.attach` call makes this fail: the word stays marked and out of the composer.
    func testCommitPendingInput_commitsTheWordBeingComposed_andGivesItToTheComposer() async throws {
        let harness = try await Harness(text: "Hello ")
        try harness.compose("にほん")

        harness.bridge.commitPendingInput()

        XCTAssertFalse(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.string, "Hello にほん")
        XCTAssertEqual(harness.model.text, "Hello にほん")
        XCTAssertEqual(harness.model.sendCount, 0)
        harness.close()
    }

    // MARK: - Escape

    /// Revert-check: replacing `field.onCancel()` with `break` in the `.cancel` case makes
    /// this fail.
    func testEscape_isHandedToTheComposer() async throws {
        let harness = try await Harness(text: "Hello")

        harness.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(harness.model.cancelCount, 1)
        XCTAssertEqual(harness.textView.string, "Hello")
        harness.close()
    }

    // MARK: - Text

    /// Revert-check: deleting the `field.text = textView.string` assignment from
    /// `textDidChange` makes this fail.
    func testTyping_reachesTheComposer() async throws {
        let harness = try await Harness(text: "")

        harness.textView.insertText("Hi there", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(harness.model.text, "Hi there")
        harness.close()
    }

    /// A send empties the draft, a restore fills it: the view follows the composer.
    ///
    /// Revert-check: deleting the `context.coordinator.applyTextFromComposer()` call from
    /// `updateNSView` makes this fail.
    func testComposerChangingTheText_replacesWhatTheFieldShows() async throws {
        let harness = try await Harness(text: "Sent a moment ago")

        harness.model.text = ""
        await harness.waitUntil { harness.textView.string.isEmpty }

        XCTAssertEqual(harness.textView.string, "")
        harness.close()
    }

    /// Undo after a send must not bring back the mail that was just sent.
    ///
    /// Revert-check: deleting `textView.undoManager?.removeAllActions()` from
    /// `applyTextFromComposer` makes this fail.
    func testComposerEmptyingTheField_leavesNothingToUndo() async throws {
        let harness = try await Harness(text: "")
        harness.textView.insertText("Sent", replacementRange: NSRange(location: 0, length: 0))
        // A failure, not a skip: a skipped test would leave the next assertion unchecked
        // with nothing to show for it.
        XCTAssertEqual(
            harness.textView.undoManager?.canUndo,
            true,
            "This text view registered no undo off screen, so the rest of this test checks nothing"
        )

        harness.model.text = ""
        await harness.waitUntil { harness.textView.string.isEmpty }

        XCTAssertEqual(harness.textView.undoManager?.canUndo, false)
        harness.close()
    }

    /// The field has an undo history of its own. Left to itself a text view records in its
    /// window's, which the sidebar's search field shares, so emptying it after a send emptied
    /// theirs too.
    ///
    /// Revert-check: deleting `undoManager(for:)` from `MacReplyTextFieldCoordinator` makes
    /// the first assertion fail.
    func testComposerEmptyingTheField_leavesTheWindowsUndoHistoryAlone() async throws {
        let harness = try await Harness(text: "")
        let windowUndoManager = try XCTUnwrap(harness.window.undoManager)
        XCTAssertFalse(harness.textView.undoManager === windowUndoManager)

        let somethingElse = NSObject()
        windowUndoManager.registerUndo(withTarget: somethingElse) { _ in }
        defer { windowUndoManager.removeAllActions(withTarget: somethingElse) }
        XCTAssertTrue(windowUndoManager.canUndo)

        harness.textView.insertText("Sent", replacementRange: NSRange(location: 0, length: 0))
        harness.model.text = ""
        await harness.waitUntil { harness.textView.string.isEmpty }

        XCTAssertTrue(windowUndoManager.canUndo)
        withExtendedLifetime(somethingElse) {}
        harness.close()
    }

    // MARK: - Height

    /// Revert-check: returning `textHeight` unclamped from `MacReplyTextField.clampedHeight`
    /// makes the first and third assertions fail.
    func testClampedHeight_isAtLeastOneLineAndAtMostTheMaximum() {
        XCTAssertEqual(
            MacReplyTextField.clampedHeight(textHeight: 0, lineHeight: 16, maximumLineCount: 5),
            16
        )
        XCTAssertEqual(
            MacReplyTextField.clampedHeight(textHeight: 47.2, lineHeight: 16, maximumLineCount: 5),
            48
        )
        XCTAssertEqual(
            MacReplyTextField.clampedHeight(textHeight: 400, lineHeight: 16, maximumLineCount: 5),
            80
        )
    }

    /// The field is one line tall when empty, grows with its text, and stops growing at its
    /// maximum, after which the text scrolls inside it.
    ///
    /// Revert-check: returning nil from `MacReplyTextField.sizeThatFits` makes this fail.
    func testField_growsWithItsTextUpToItsMaximumLineCount() async throws {
        let harness = try await Harness(text: "")
        let oneLine = harness.fieldHeight
        XCTAssertGreaterThan(oneLine, 10)
        XCTAssertLessThan(oneLine, 24)

        harness.model.text = "One\nTwo\nThree"
        await harness.waitUntil { harness.fieldHeight > oneLine * 2.5 }
        XCTAssertEqual(harness.fieldHeight, oneLine * 3, accuracy: 3)

        harness.model.text = Array(repeating: "Line", count: 30).joined(separator: "\n")
        await harness.waitUntil { harness.fieldHeight > oneLine * 4.5 }
        XCTAssertEqual(
            harness.fieldHeight,
            oneLine * CGFloat(ChatComposerMetrics.mac.maximumLineCount),
            accuracy: 5
        )
        harness.close()
    }

    /// Text typed in the view, not set by the composer, grows the field too.
    ///
    /// Revert-check: deleting `invalidateIntrinsicContentSize()` from `textDidChange` is NOT
    /// caught here on macOS 27.2: SwiftUI asks the field for its size again when the binding
    /// changes. HONEST SCOPE: the call stays as the documented way to ask, and this test pins
    /// the growth, by whichever route.
    func testTypingLines_growsTheField() async throws {
        let harness = try await Harness(text: "")
        let oneLine = harness.fieldHeight

        harness.textView.insertText("One\nTwo\nThree", replacementRange: NSRange(location: 0, length: 0))
        await harness.waitUntil { harness.fieldHeight > oneLine * 2.5 }

        XCTAssertEqual(harness.fieldHeight, oneLine * 3, accuracy: 3)
        harness.close()
    }

    // MARK: - Focus

    /// A chat asks for the focus as it appears; the field takes it once it is in its window,
    /// and tells the chat.
    ///
    /// Revert-check: deleting the `bridge.attach(field: self) { ... }` call from the
    /// coordinator's `onWindowChange` makes this fail.
    func testFocusRequestedBeforeTheFieldExists_isTakenWhenItEntersItsWindow() async throws {
        let bridge = ReplyFieldFocusBridge()
        bridge.requestFocus(true)

        let harness = try await Harness(text: "", bridge: bridge)
        await harness.waitUntil { bridge.isFocused }

        XCTAssertTrue(harness.window.firstResponder === harness.textView)
        XCTAssertTrue(bridge.isFocused)
        harness.close()
    }

    /// The chat observes the bridge, and AppKit tells a text view it lost the focus while
    /// SwiftUI is taking the view out of its window: inside a SwiftUI update, where a publish
    /// is a fault. So the field's word reaches the bridge a turn of the run loop later.
    ///
    /// Revert-check: calling `bridge?.fieldDidChangeFocus(isFocused)` directly, without the
    /// `DispatchQueue.main.async`, in the coordinator's `onFocusChange` makes the first
    /// assertion fail.
    func testFocusChange_reachesTheBridgeOnALaterTurn_notInsideTheChange() async throws {
        let harness = try await Harness(text: "")

        XCTAssertTrue(harness.window.makeFirstResponder(harness.textView))
        XCTAssertFalse(harness.bridge.isFocused, "The report was published inside the change")

        await harness.waitUntil { harness.bridge.isFocused }
        XCTAssertTrue(harness.bridge.isFocused)
        harness.close()
    }

    /// Revert-check: deleting the `onFocusChange?(false)` call from
    /// `MacReplyTextView.resignFirstResponder` makes the last assertion fail.
    func testFocusRequestsAfterTheFieldExists_giveAndTakeTheFocus() async throws {
        let harness = try await Harness(text: "")
        XCTAssertFalse(harness.bridge.isFocused)

        harness.bridge.requestFocus(true)
        await harness.waitUntil { harness.bridge.isFocused }
        XCTAssertTrue(harness.window.firstResponder === harness.textView)

        harness.bridge.requestFocus(false)
        await harness.waitUntil { !harness.bridge.isFocused }
        XCTAssertFalse(harness.window.firstResponder === harness.textView)
        XCTAssertFalse(harness.bridge.isFocused)
        harness.close()
    }

    /// Dropping the composer's focus must not take the focus from something else: the
    /// sidebar's list, the search field.
    ///
    /// Revert-check: replacing `else if window.firstResponder === textView` with `else` in
    /// the coordinator's `applyFocus` makes this fail.
    func testDroppingTheFocus_whenSomethingElseHasIt_leavesItThere() async throws {
        let harness = try await Harness(text: "")
        let other = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        harness.window.contentView?.addSubview(other)
        XCTAssertTrue(harness.window.makeFirstResponder(other))

        harness.bridge.requestFocus(false)
        // The request is applied in a block the call put on the main queue, so a block put
        // there after it runs once the request has been applied.
        await harness.nextMainQueueTurn()

        XCTAssertTrue(harness.window.firstResponder === other)
        harness.close()
    }
}

/// A view that takes the focus, standing in for the sidebar's list.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// What the field's closures saw.
@MainActor
private final class FieldModel: ObservableObject {
    @Published var text: String
    var canSend: Bool
    var sendCount = 0
    var cancelCount = 0
    var textAtSend: [String] = []
    /// Each text the field asked `canSend` about.
    var textAskedAbout: [String] = []
    /// Changed to make SwiftUI update the field for a reason other than its text.
    @Published var unrelated = 0
    /// How many times `FieldHost.body` ran.
    var bodyEvaluations = 0

    init(text: String, canSend: Bool) {
        self.text = text
        self.canSend = canSend
    }
}

/// The field alone, at a fixed width, bound to a model.
private struct FieldHost: View {
    @ObservedObject var model: FieldModel
    let bridge: ReplyFieldFocusBridge
    let key: MacReplyKeyEvent

    var body: some View {
        let _ = model.bodyEvaluations += 1
        MacReplyTextField(
            text: $model.text,
            fontSize: ChatComposerMetrics.mac.fontSize,
            maximumLineCount: ChatComposerMetrics.mac.maximumLineCount,
            focusBridge: bridge,
            canSend: { [model] text in
                model.textAskedAbout.append(text)
                return model.canSend
            },
            onSend: { [model] in
                model.sendCount += 1
                model.textAtSend.append(model.text)
            },
            onCancel: { [model] in model.cancelCount += 1 },
            currentKey: { key }
        )
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The field mounted in a window that is never shown.
@MainActor
private final class Harness {
    let model: FieldModel
    let bridge: ReplyFieldFocusBridge
    let window: NSWindow
    let host: NSHostingView<FieldHost>
    let textView: MacReplyTextView

    init(
        text: String,
        canSend: Bool = true,
        key: MacReplyKeyEvent = MacReplyKeyEvent(isShiftDown: false, isRepeat: false),
        bridge existingBridge: ReplyFieldFocusBridge? = nil
    ) async throws {
        let bridge = existingBridge ?? ReplyFieldFocusBridge()
        model = FieldModel(text: text, canSend: canSend)
        self.bridge = bridge
        window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: FieldHost(model: model, bridge: bridge, key: key))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        // The hosting view sits in a plain view, so a test can put another view beside it:
        // a hosting view takes no subviews of its own.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(host)
        window.contentView = container
        host.layoutSubtreeIfNeeded()

        var found: MacReplyTextView?
        let deadline = Date().addingTimeInterval(5)
        while found == nil, Date() < deadline {
            found = Self.textView(in: host)
            if found == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        textView = try XCTUnwrap(found, "The field's text view was not built")
        host.layoutSubtreeIfNeeded()
    }

    /// The height SwiftUI gave the field: its scroll view's.
    var fieldHeight: CGFloat {
        host.layoutSubtreeIfNeeded()
        return textView.enclosingScrollView?.frame.height ?? 0
    }

    func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    /// Puts `word` at the end of the field as text an input method is still composing.
    ///
    /// Fails, where it used to skip, if the view takes no marked text off screen: a skipped
    /// test leaves the guard it names unchecked with nothing to show for it, and CI runs no
    /// Mac tests to notice.
    func compose(_ word: String, file: StaticString = #filePath, line: UInt = #line) throws {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.setMarkedText(
            word,
            selectedRange: NSRange(location: (word as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        guard textView.hasMarkedText() else {
            XCTFail("This text view would not take marked text off screen", file: file, line: line)
            throw CocoaError(.featureUnsupported)
        }
    }

    /// Returns once everything already on the main queue has run.
    func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func close() {
        window.contentView = nil
    }

    private static func textView(in view: NSView) -> MacReplyTextView? {
        if let textView = view as? MacReplyTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
#endif
