import XCTest
@testable import esc_chatmail

/// The focus of a reply field `FocusState` does not reach (`ReplyFieldFocusBridge`): requests
/// made before the field exists, and what the chat is told. Pure, so it runs in the iOS suite
/// and in `Mac.xctestplan`.
///
/// HONEST SCOPE: the bridge alone, with a closure standing in for the field. That the Mac's
/// text view attaches, takes the focus and reports it is `MacReplyTextFieldTests`'.
@MainActor
final class ReplyFieldFocusBridgeTests: XCTestCase {
    /// Stands in for the field that attaches.
    private let field = NSObject()

    /// A chat asks for the focus as it appears, before its field is in a window.
    ///
    /// Revert-check: deleting the `pendingRequest = wantsFocus` line from `requestFocus`
    /// makes this fail: the request is lost, and the caret never lands in the field.
    func testRequestBeforeTheFieldAttaches_isAppliedWhenItDoes_once() {
        let bridge = ReplyFieldFocusBridge()
        var applied: [Bool] = []

        bridge.requestFocus(true)
        XCTAssertEqual(applied, [])

        bridge.attach(field: field) { applied.append($0) }
        XCTAssertEqual(applied, [true])

        // A second attach (the field re-entering a window) does not replay it.
        bridge.attach(field: field) { applied.append($0) }
        XCTAssertEqual(applied, [true])
    }

    /// Revert-check: storing the request instead of applying it when a field is attached
    /// (`pendingRequest = wantsFocus` on both branches) makes this fail.
    func testRequestAfterTheFieldAttached_goesStraightToTheField() {
        let bridge = ReplyFieldFocusBridge()
        var applied: [Bool] = []
        bridge.attach(field: field) { applied.append($0) }

        bridge.requestFocus(true)
        bridge.requestFocus(false)

        XCTAssertEqual(applied, [true, false])
    }

    /// Only the latest request made before the field attached counts.
    ///
    /// Revert-check: keeping the first pending request (`pendingRequest = pendingRequest ??
    /// wantsFocus`) makes this fail.
    func testRequestsBeforeTheFieldAttaches_theLatestWins() {
        let bridge = ReplyFieldFocusBridge()
        var applied: [Bool] = []

        bridge.requestFocus(true)
        bridge.requestFocus(false)
        bridge.attach(field: field) { applied.append($0) }

        XCTAssertEqual(applied, [false])
    }

    /// Revert-check: deleting `fieldDidChangeFocus(false)` from `detach` makes the last
    /// assertion fail: a chat whose field left its window would still read as focused.
    func testFocusReports_reachIsFocused_andAFieldThatLeavesItsWindowIsNotFocused() {
        let bridge = ReplyFieldFocusBridge()
        bridge.attach(field: field) { _ in }
        XCTAssertFalse(bridge.isFocused)

        bridge.fieldDidChangeFocus(true)
        XCTAssertTrue(bridge.isFocused)

        bridge.detach(field: field)
        XCTAssertFalse(bridge.isFocused)
    }

    /// The chat observes the bridge, so an unchanged report must not re-evaluate it.
    ///
    /// Revert-check: deleting the `guard self.isFocused != isFocused` line makes this fail.
    func testUnchangedFocusReport_publishesNothing() {
        let bridge = ReplyFieldFocusBridge()
        var publishCount = 0
        let subscription = bridge.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }

        bridge.fieldDidChangeFocus(false)
        XCTAssertEqual(publishCount, 0)

        bridge.fieldDidChangeFocus(true)
        bridge.fieldDidChangeFocus(true)
        XCTAssertEqual(publishCount, 1)
    }

    /// After the field detaches, a request waits for the next field instead of reaching the
    /// one that is gone.
    ///
    /// Revert-check: deleting `applyFocus = nil` from `detach` makes this fail.
    func testRequestAfterDetach_waitsForTheNextField() {
        let bridge = ReplyFieldFocusBridge()
        var first: [Bool] = []
        var second: [Bool] = []
        bridge.attach(field: field) { first.append($0) }
        bridge.detach(field: field)

        bridge.requestFocus(true)
        XCTAssertEqual(first, [])

        bridge.attach(field: NSObject()) { second.append($0) }
        XCTAssertEqual(second, [true])
    }

    /// A field says it left a turn of the run loop after it did. If the chat has built another
    /// field by then, the late word from the old one must not take the new one's place away.
    ///
    /// Revert-check: deleting the `guard attachedField == ObjectIdentifier(field)` line from
    /// `detach` makes this fail.
    func testDetachFromAFieldThatIsNoLongerTheAttachedOne_changesNothing() {
        let bridge = ReplyFieldFocusBridge()
        let oldField = NSObject()
        var applied: [Bool] = []
        bridge.attach(field: oldField) { _ in }
        bridge.attach(field: field) { applied.append($0) }
        bridge.fieldDidChangeFocus(true)

        bridge.detach(field: oldField)

        XCTAssertTrue(bridge.isFocused)
        bridge.requestFocus(false)
        XCTAssertEqual(applied, [false])
    }
}
