#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// What the rich text on a pasteboard holds, for a paste into the Mac's reply field
/// (`MacPastedRichText`). Pasteboards of the test's own, never the one the user copies to.
///
/// HONEST SCOPE: the rich text is built here with AppKit, as a text view builds its own
/// copy. What a web view's Copy Image writes was measured apart, in a throwaway program
/// (`docs/mac-app-plan.md`, "Files and images pasted into the reply field"): one file and
/// nothing else, which is the first case below.
final class MacPastedRichTextTests: XCTestCase {
    private let size = CGSize(width: 24, height: 16)

    private func pasteboard(richText: Data?) -> NSPasteboard {
        let pasteboard = FakeDraggingInfo.pasteboard(holding: [])
        if let richText {
            pasteboard.addTypes([.rtfd], owner: nil)
            pasteboard.setData(richText, forType: .rtfd)
        }
        return pasteboard
    }

    /// Revert-check: answering `contents.attachedFiles.first` from
    /// `MacPastedRichText.solePicture` whatever else the rich text holds makes the words'
    /// and the two files' assertions fail: a passage copied with a picture of itself would
    /// be attached as the first file in it.
    func testSolePicture_isTheOneFile_whereTheRichTextHoldsNothingElse() throws {
        let jpeg = try TestImageData.encoded(as: .jpeg, pixelSize: size, picture: .photograph, hasAlphaChannel: false)
        let png = try TestImageData.encoded(as: .png, pixelSizes: [size])
        let alone = pasteboard(richText: try TestRichTextData.rtfd([.file(jpeg, named: "cat.jpg")]))
        let withWhiteSpace = pasteboard(richText: try TestRichTextData.rtfd([.file(png, named: "a.png"), .words("\n")]))
        let withWords = pasteboard(richText: try TestRichTextData.rtfd([.words("A cat "), .file(jpeg, named: "cat.jpg")]))
        let two = pasteboard(richText: try TestRichTextData.rtfd([.file(png, named: "a.png"), .file(jpeg, named: "b.jpg")]))
        let wordsOnly = pasteboard(richText: try TestRichTextData.rtfd([.words("Some words")]))
        let none = pasteboard(richText: nil)
        let unreadable = pasteboard(richText: Data("not rich text".utf8))
        defer { [alone, withWhiteSpace, withWords, two, wordsOnly, none, unreadable].forEach { $0.releaseGlobally() } }

        XCTAssertEqual(MacPastedRichText.solePicture(on: alone), .init(data: jpeg, fileExtension: "jpeg"))
        XCTAssertEqual(MacPastedRichText.solePicture(on: withWhiteSpace), .init(data: png, fileExtension: "png"))

        XCTAssertNil(MacPastedRichText.solePicture(on: withWords))
        XCTAssertNil(MacPastedRichText.solePicture(on: two))
        XCTAssertNil(MacPastedRichText.solePicture(on: wordsOnly))
        XCTAssertNil(MacPastedRichText.solePicture(on: none))
        XCTAssertNil(MacPastedRichText.solePicture(on: unreadable))
    }

    /// The name a file has in the rich text is whatever a page or a sender called it. What
    /// the file is, is read from its bytes.
    ///
    /// HONEST SCOPE: no one line undone makes this fail, because `contents(on:)` does not
    /// keep the names at all. It pins that a name in the rich text never names the file: a
    /// PNG called `cat.exe` written under that extension would be attached as a plain file.
    func testSolePicture_isNamedForItsBytes_notForItsNameInTheRichText() throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [size])
        let copied = pasteboard(richText: try TestRichTextData.rtfd([.file(png, named: "cat.exe")]))
        defer { copied.releaseGlobally() }

        XCTAssertEqual(MacPastedRichText.solePicture(on: copied), .init(data: png, fileExtension: "png"))
    }

    /// Revert-check: answering every attached file from `MacPastedRichText.pictures`
    /// (`Attachable(data: $0, fileExtension: "png")` in place of
    /// `PastedImageEncoder.attachable`) makes the count fail: the text file is attached as a
    /// picture, and the TIFF as it came.
    func testPictures_areThePicturesInOrder_eachInAFormTheImportTakes() throws {
        let png = try TestImageData.encoded(as: .png, pixelSizes: [size])
        let tiff = try TestImageData.encoded(as: .tiff, pixelSizes: [size])
        let copied = pasteboard(richText: try TestRichTextData.rtfd([
            .words("Two pictures and a note: "),
            .file(png, named: "a.png"),
            .file(Data("hello".utf8), named: "note.txt"),
            .file(tiff, named: "Pasted Graphic.tiff")
        ]))
        let none = pasteboard(richText: nil)
        defer {
            copied.releaseGlobally()
            none.releaseGlobally()
        }

        let pictures = MacPastedRichText.pictures(on: copied)

        XCTAssertEqual(pictures.count, 2)
        XCTAssertEqual(pictures.first, .init(data: png, fileExtension: "png"))
        XCTAssertEqual(pictures.last?.fileExtension, "png")
        XCTAssertEqual(pictures.last.flatMap { TestImageData.typeIdentifier(of: $0.data) }, UTType.png.identifier)
        XCTAssertEqual(pictures.last.map { TestImageData.pixelSizes(of: $0.data) }, [size])
        XCTAssertEqual(MacPastedRichText.pictures(on: none), [])
    }

    /// Revert-check: answering `hasWords: false` always from `MacPastedRichText.contents`
    /// makes the second assertion fail.
    func testContents_areTheAttachedFilesInOrder_andWhetherThereAreWords() throws {
        let first = Data("one".utf8)
        let second = Data("two".utf8)
        let files = pasteboard(richText: try TestRichTextData.rtfd([
            .file(first, named: "1.txt"), .words(" \n"), .file(second, named: "2.txt")
        ]))
        let words = pasteboard(richText: try TestRichTextData.rtfd([.words("x"), .file(first, named: "1.txt")]))
        defer {
            files.releaseGlobally()
            words.releaseGlobally()
        }

        let contents = try XCTUnwrap(MacPastedRichText.contents(on: files))
        XCTAssertEqual(contents.attachedFiles, [first, second])
        XCTAssertFalse(contents.hasWords)
        XCTAssertEqual(MacPastedRichText.contents(on: words)?.hasWords, true)
    }
}
#endif
