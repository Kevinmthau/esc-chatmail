import XCTest
@testable import esc_chatmail

/// What Paste does in the Mac's reply field, from what was copied (`ReplyFieldPastePolicy`).
/// Plain values, so this runs in the iOS suite and in `Mac.xctestplan`.
final class ReplyFieldPastePolicyTests: XCTestCase {
    private func action(
        files: Bool = false,
        text: Bool = false,
        image: Bool = false,
        richText: Bool = false,
        textIsOnlyTheAddress: Bool = false,
        marks: ReplyFieldPastePolicy.PictureMarks = .none
    ) -> ReplyFieldPastePolicy.Action {
        ReplyFieldPastePolicy.action(
            carriesFiles: files,
            carriesText: text,
            carriesImage: image,
            carriesRichTextWithAttachments: richText,
            textIsOnlyTheCopiedAddress: textIsOnlyTheAddress,
            pictureMarksInText: marks
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
        XCTAssertEqual(action(files: true, text: true, richText: true, marks: .only), .attachFiles)
    }

    /// Revert-check: attaching the image whenever there is one, whatever the text is
    /// (`guard carriesImage else { … }; return .attachImage` in
    /// `ReplyFieldPastePolicy.action`), makes the second assertion fail: cells copied from a
    /// spreadsheet would be attached as a picture of them.
    func testAction_text_isPastedAsText_withAPictureBesideItOrNot() {
        XCTAssertEqual(action(text: true), .pasteAsText)
        XCTAssertEqual(action(text: true, image: true), .pasteAsText)
        // Rich text with no picture in it is words too.
        XCTAssertEqual(action(text: true, richText: true), .pasteAsText)
        XCTAssertEqual(action(text: true, image: true, richText: true), .pasteAsText)
    }

    /// Revert-check: returning `.pasteAsText` for an image alone from
    /// `ReplyFieldPastePolicy.action` makes this fail: a screenshot on the clipboard would
    /// paste as nothing.
    func testAction_anImageAlone_isAttached() {
        XCTAssertEqual(action(image: true), .attachImage)
        // As Copy Image in a web view leaves it (measured 2026-11-14): the picture, rich
        // text that holds its file, and no text.
        XCTAssertEqual(action(image: true, richText: true), .attachImage)
    }

    /// A picture whose only text is its own address. No app is known to write one: Copy
    /// Image in a web view, which this was written for, writes no text (measured
    /// 2026-11-14).
    ///
    /// Revert-check: returning `.pasteAsText` wherever text was copied, as before
    /// (`if carriesText { return .pasteAsText }` above the image in
    /// `ReplyFieldPastePolicy.action`), makes the first assertion fail: such a picture is
    /// pasted as its address.
    func testAction_anImageWhoseOnlyTextIsItsAddress_isAttached() {
        XCTAssertEqual(action(text: true, image: true, textIsOnlyTheAddress: true), .attachImage)
        // An address with no picture beside it is text like any other.
        XCTAssertEqual(action(text: true, textIsOnlyTheAddress: true), .pasteAsText)
    }

    func testAction_nothingTheFieldAttaches_isLeftToTheField() {
        XCTAssertEqual(action(), .pasteAsText)
        XCTAssertEqual(action(richText: true), .pasteAsText)
    }

    // MARK: - Pictures copied as rich text

    /// A picture selected in a rich text view is copied as RTFD and, as plain text, the
    /// mark that stands for it, with no image beside them (measured 2026-11-14). The picture
    /// is what was copied.
    ///
    /// Revert-check: returning `.pasteAsText` for `.only` in
    /// `ReplyFieldPastePolicy.action` makes this fail: the mark is typed into the reply and
    /// no picture is attached.
    func testAction_richTextThatIsOnlyPictures_attachesThem() {
        XCTAssertEqual(action(text: true, richText: true, marks: .only), .attachPicturesInRichText)
    }

    /// Where the pasteboard has the picture itself as well, that one is attached, as an
    /// image with no text is.
    ///
    /// Revert-check: answering `.attachPicturesInRichText` for `.only` whatever else the
    /// pasteboard has makes this fail.
    func testAction_anImageWhoseOnlyTextIsItsMark_isAttachedAsTheImage() {
        XCTAssertEqual(action(text: true, image: true, richText: true, marks: .only), .attachImage)
    }

    /// Revert-check: returning `.pasteAsText` for `.amongWords` in
    /// `ReplyFieldPastePolicy.action` makes both fail: the words are pasted with a mark
    /// where each picture was.
    func testAction_wordsWithPicturesAmongThem_arePastedWithoutTheMarks() {
        XCTAssertEqual(action(text: true, richText: true, marks: .amongWords), .pasteTextWithoutPictureMarks)
        XCTAssertEqual(
            action(text: true, image: true, richText: true, marks: .amongWords),
            .pasteTextWithoutPictureMarks
        )
    }

    /// A mark in text that came with no rich text stands for nothing that can be attached,
    /// and that text is not read to look for one.
    ///
    /// Revert-check: dropping the `guard carriesRichTextWithAttachments` from
    /// `ReplyFieldPastePolicy.action` makes this fail.
    func testAction_marksInTextCopiedWithNoRichText_areNotAskedAbout() {
        XCTAssertEqual(action(text: true, marks: .only), .pasteAsText)
        XCTAssertEqual(action(text: true, image: true, marks: .amongWords), .pasteAsText)
    }

    /// Revert-check: counting white space as words in `ReplyFieldPastePolicy.pictureMarks`
    /// (dropping the `whitespacesAndNewlines` term) makes the second and third assertions of
    /// the second group fail: two pictures on two lines would be pasted as text. Looking for
    /// the mark among `Character`s (`text.contains(Character(pictureMark))`) makes the last
    /// assertion fail.
    func testPictureMarks_none_only_orAmongWords() {
        let mark = "\u{FFFC}"

        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: nil), .none)
        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: ""), .none)
        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: "Some words"), .none)

        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: mark), .only)
        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: "\(mark)\n\(mark)"), .only)
        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: " \(mark)\t\n"), .only)

        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: "before \(mark) after"), .amongWords)
        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: "\(mark)x"), .amongWords)
        // A mark with a combining accent on it is one `Character` that is not the mark.
        XCTAssertEqual(ReplyFieldPastePolicy.pictureMarks(in: "\(mark)\u{301}"), .amongWords)
    }

    /// Revert-check: returning `text` as it came from
    /// `ReplyFieldPastePolicy.removingPictureMarks` makes this fail.
    func testRemovingPictureMarks_leavesEverythingElse() {
        let mark = "\u{FFFC}"

        XCTAssertEqual(ReplyFieldPastePolicy.removingPictureMarks(from: "before \(mark) after"), "before  after")
        XCTAssertEqual(ReplyFieldPastePolicy.removingPictureMarks(from: "\(mark)a\(mark)b\(mark)"), "ab")
        XCTAssertEqual(ReplyFieldPastePolicy.removingPictureMarks(from: "No marks"), "No marks")
        XCTAssertEqual(ReplyFieldPastePolicy.removingPictureMarks(from: "caf\(mark)\u{301}e"), "caf\u{301}e")
    }

    // MARK: - Behind a sheet

    /// Revert-check: answering true always from `ReplyFieldPastePolicy.fieldTakesPaste`
    /// makes the second assertion fail: text is pasted into the draft behind a sheet.
    func testFieldTakesPaste_notWhileItsWindowHasASheet() {
        XCTAssertTrue(ReplyFieldPastePolicy.fieldTakesPaste(windowHasSheet: false))
        XCTAssertFalse(ReplyFieldPastePolicy.fieldTakesPaste(windowHasSheet: true))
    }

    /// The Edit menu's validation asks this, with no paste asked for, so it is decided from
    /// the kinds alone: the field answers for files and for a picture with no text, and
    /// leaves the rest to the text view, a picture copied with text included. The text view
    /// enables Paste for the text, so what the text is need not be read to enable it.
    ///
    /// Revert-check: answering `carriesFiles` alone from
    /// `ReplyFieldPastePolicy.fieldEnablesPaste` makes the picture's assertion fail: with
    /// only an image copied Paste is disabled, and Command-V never reaches the field.
    /// Answering `carriesFiles || carriesImage` makes the assertion on a picture with text
    /// fail.
    func testFieldEnablesPaste_forFilesAndAPictureWithNoText_fromTheKindsAlone() {
        func enables(files: Bool = false, text: Bool = false, image: Bool = false) -> Bool {
            ReplyFieldPastePolicy.fieldEnablesPaste(carriesFiles: files, carriesText: text, carriesImage: image)
        }

        XCTAssertTrue(enables(files: true))
        XCTAssertTrue(enables(files: true, text: true))
        XCTAssertTrue(enables(files: true, text: true, image: true))
        XCTAssertTrue(enables(image: true))

        XCTAssertFalse(enables(text: true, image: true))
        XCTAssertFalse(enables(text: true))
        XCTAssertFalse(enables())
    }

    /// The field never answers for a paste it would leave to the text view, whatever the
    /// text turns out to be: where `fieldEnablesPaste` says yes, `action` attaches.
    ///
    /// Revert-check: answering `carriesFiles || carriesImage` from
    /// `ReplyFieldPastePolicy.fieldEnablesPaste` makes this fail for a picture copied with
    /// words: the field would enable Paste for a paste that is the text view's.
    func testFieldEnablesPaste_onlyWhereAPasteAttaches_whateverTheTextIs() {
        for files in [false, true] {
            for text in [false, true] {
                for image in [false, true] where ReplyFieldPastePolicy.fieldEnablesPaste(
                    carriesFiles: files,
                    carriesText: text,
                    carriesImage: image
                ) {
                    for isAddress in [false, true] {
                        for richText in [false, true] {
                            for marks in [ReplyFieldPastePolicy.PictureMarks.none, .only, .amongWords] {
                                let action = ReplyFieldPastePolicy.action(
                                    carriesFiles: files,
                                    carriesText: text,
                                    carriesImage: image,
                                    carriesRichTextWithAttachments: richText,
                                    textIsOnlyTheCopiedAddress: isAddress,
                                    pictureMarksInText: marks
                                )
                                XCTAssertTrue(
                                    action == .attachFiles || action == .attachImage,
                                    "files \(files), text \(text), image \(image), address \(isAddress), "
                                        + "rich text \(richText), marks \(marks): \(action)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Whether the text is the address, and what marks it has, are found by reading the
    /// text, which can be long. Each is asked only where the answer decides anything: the
    /// address of a picture and text together, the marks of text and rich text together, and
    /// neither where a file was copied.
    ///
    /// Revert-check: asking `textIsOnlyTheCopiedAddress()` at the top of
    /// `ReplyFieldPastePolicy.action`, before the files, the image and the text are asked
    /// about, makes the first count fail; asking `pictureMarksInText()` there makes the
    /// second fail.
    func testAction_asksWhatTheTextIs_onlyWhereTheAnswerDecides() {
        var askedForAddress = 0
        var askedForMarks = 0
        func isAddress() -> Bool {
            askedForAddress += 1
            return false
        }
        func marks() -> ReplyFieldPastePolicy.PictureMarks {
            askedForMarks += 1
            return .none
        }
        for files in [false, true] {
            for text in [false, true] {
                for image in [false, true] {
                    for richText in [false, true] {
                        _ = ReplyFieldPastePolicy.action(
                            carriesFiles: files,
                            carriesText: text,
                            carriesImage: image,
                            carriesRichTextWithAttachments: richText,
                            textIsOnlyTheCopiedAddress: isAddress(),
                            pictureMarksInText: marks()
                        )
                    }
                }
            }
        }

        // A picture and text, with rich text or without.
        XCTAssertEqual(askedForAddress, 2)
        // Text and rich text, with a picture or without.
        XCTAssertEqual(askedForMarks, 2)
    }

    /// A picture whose text is its own address is attached without the marks being asked
    /// about: the text has been read once already and decided it.
    ///
    /// Revert-check: asking `pictureMarksInText()` before `textIsOnlyTheCopiedAddress()` in
    /// `ReplyFieldPastePolicy.action` makes this fail.
    func testAction_aPictureWithItsAddress_isDecidedBeforeTheMarksAreAsked() {
        var askedForMarks = 0
        func marks() -> ReplyFieldPastePolicy.PictureMarks {
            askedForMarks += 1
            return .none
        }

        let action = ReplyFieldPastePolicy.action(
            carriesFiles: false,
            carriesText: true,
            carriesImage: true,
            carriesRichTextWithAttachments: true,
            textIsOnlyTheCopiedAddress: true,
            pictureMarksInText: marks()
        )

        XCTAssertEqual(action, .attachImage)
        XCTAssertEqual(askedForMarks, 0)
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
