import XCTest
@testable import esc_chatmail

/// What Paste does in the Mac's reply field, from what was copied (`ReplyFieldPastePolicy`).
/// Plain values, so this runs in the iOS suite and in `Mac.xctestplan`.
final class ReplyFieldPastePolicyTests: XCTestCase {
    private func action(files: Bool = false, text: Bool = false, image: Bool = false) -> ReplyFieldPastePolicy.Action {
        ReplyFieldPastePolicy.action(carriesFiles: files, carriesText: text, carriesImage: image)
    }

    /// A file copied in the Finder puts its name on the pasteboard as text as well, and its
    /// icon as a picture.
    ///
    /// Revert-check: asking about text before files in `ReplyFieldPastePolicy.action` makes
    /// this fail: the copied file would be pasted as its path, which is the bug.
    func testAction_copiedFiles_areAttached_whateverElseWasCopiedWithThem() {
        XCTAssertEqual(action(files: true), .attachFiles)
        XCTAssertEqual(action(files: true, text: true), .attachFiles)
        XCTAssertEqual(action(files: true, text: true, image: true), .attachFiles)
    }

    /// Revert-check: asking about the image before the text in
    /// `ReplyFieldPastePolicy.action` makes the second assertion fail: cells copied from a
    /// spreadsheet would be attached as a picture of them.
    func testAction_text_isPastedAsText_withAPictureBesideItOrNot() {
        XCTAssertEqual(action(text: true), .pasteAsText)
        XCTAssertEqual(action(text: true, image: true), .pasteAsText)
    }

    /// Revert-check: returning `.pasteAsText` for an image alone from
    /// `ReplyFieldPastePolicy.action` makes this fail: a screenshot on the clipboard would
    /// paste as nothing.
    func testAction_anImageAlone_isAttached() {
        XCTAssertEqual(action(image: true), .attachImage)
    }

    func testAction_nothingTheFieldAttaches_isLeftToTheField() {
        XCTAssertEqual(action(), .pasteAsText)
    }
}
