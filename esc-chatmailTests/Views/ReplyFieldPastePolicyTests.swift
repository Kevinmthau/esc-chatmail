import XCTest
@testable import esc_chatmail

/// What Paste does in the Mac's reply field, from what was copied (`ReplyFieldPastePolicy`).
/// Plain values, so this runs in the iOS suite and in `Mac.xctestplan`.
final class ReplyFieldPastePolicyTests: XCTestCase {
    private func action(
        files: Bool = false,
        text: Bool = false,
        image: Bool = false,
        textIsOnlyTheAddress: Bool = false
    ) -> ReplyFieldPastePolicy.Action {
        ReplyFieldPastePolicy.action(
            carriesFiles: files,
            carriesText: text,
            carriesImage: image,
            textIsOnlyTheCopiedAddress: textIsOnlyTheAddress
        )
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
        XCTAssertEqual(action(files: true, text: true, image: true, textIsOnlyTheAddress: true), .attachFiles)
    }

    /// Revert-check: attaching the image whenever there is one, whatever the text is
    /// (`guard carriesImage else { … }; return .attachImage` in
    /// `ReplyFieldPastePolicy.action`), makes the second assertion fail: cells copied from a
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

    /// Copy Image in a web view writes the picture and, as text, the address it came from.
    ///
    /// Revert-check: returning `.pasteAsText` wherever text was copied, as before
    /// (`if carriesText { return .pasteAsText }` above the image in
    /// `ReplyFieldPastePolicy.action`), makes the first assertion fail: an image copied in
    /// Safari is pasted as its address.
    func testAction_anImageWhoseOnlyTextIsItsAddress_isAttached() {
        XCTAssertEqual(action(text: true, image: true, textIsOnlyTheAddress: true), .attachImage)
        // An address with no picture beside it is text like any other.
        XCTAssertEqual(action(text: true, textIsOnlyTheAddress: true), .pasteAsText)
    }

    func testAction_nothingTheFieldAttaches_isLeftToTheField() {
        XCTAssertEqual(action(), .pasteAsText)
    }

    /// Whether the text is the address is found by reading the text, and Paste is decided at
    /// every validation of the Edit menu. It is asked only where the answer decides anything:
    /// a picture and text together, and no file.
    ///
    /// Revert-check: asking `textIsOnlyTheCopiedAddress` at the top of
    /// `ReplyFieldPastePolicy.action`, before the files, the image and the text are asked
    /// about, makes the count fail: 8, not 1.
    func testAction_asksWhatTheTextIs_onlyOfAPictureAndTextCopiedTogether() {
        var asked = 0
        func isAddress() -> Bool {
            asked += 1
            return true
        }
        for files in [false, true] {
            for text in [false, true] {
                for image in [false, true] {
                    _ = ReplyFieldPastePolicy.action(
                        carriesFiles: files,
                        carriesText: text,
                        carriesImage: image,
                        textIsOnlyTheCopiedAddress: isAddress()
                    )
                }
            }
        }

        XCTAssertEqual(asked, 1)
    }

    // MARK: - Text that is only the picture's address

    /// The pasteboard's text and its URL are one string where the text is the address.
    ///
    /// Revert-check: answering true from `ReplyFieldPastePolicy.textIsOnlyTheAddress` for
    /// any text on a pasteboard that carries a URL (`return text == address ||
    /// !address.isEmpty`) makes the second group fail: words copied beside a picture and a
    /// link would be dropped for the picture.
    func testTextIsOnlyTheAddress_whereTheTextIsTheCopiedURL_andNothingElse() {
        let address = "https://example.com/pictures/cat.png"

        XCTAssertTrue(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: address, address: address))
        XCTAssertTrue(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: " \(address)\n", address: address))
        // No scheme is asked for: an inline picture's address is the picture itself.
        let inline = "data:image/png;base64,iVBORw0KGgo="
        XCTAssertTrue(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: inline, address: inline))

        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: "A cat: \(address)", address: address))
        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: "A1\tB1", address: address))
        XCTAssertFalse(
            ReplyFieldPastePolicy.textIsOnlyTheAddress(text: "https://example.com/other.png", address: address)
        )
    }

    /// Revert-check: dropping the `!text.isEmpty` term from
    /// `ReplyFieldPastePolicy.textIsOnlyTheAddress` makes the last two assertions fail: an
    /// empty text beside an empty URL would count as an address.
    func testTextIsOnlyTheAddress_withNoTextOrNoURL_isNot() {
        let address = "https://example.com/pictures/cat.png"

        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: address, address: nil))
        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: nil, address: address))
        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: nil, address: nil))
        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: "", address: ""))
        XCTAssertFalse(ReplyFieldPastePolicy.textIsOnlyTheAddress(text: " \n", address: " "))
    }
}
