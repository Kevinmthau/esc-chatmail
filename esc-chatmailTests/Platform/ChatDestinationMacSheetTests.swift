import XCTest
import Contacts
import CoreData
@testable import esc_chatmail

/// Which Mac sheet size and close control each chat destination gets
/// (`ChatDestination+MacSheet`). The mapping is platform-neutral, so it is pinned here on iOS.
///
/// HONEST SCOPE: no test presents a sheet. `ChatView` never mounts in the unit-test host, so the
/// chrome being applied there (`View.appSheet`, `MacSheetChromeModifier`) is not exercised;
/// `AppSheetSourceTests` pins only that no sheet bypasses the presenter. What the chrome does
/// was measured with a throwaway Mac program outside the repo that compiled these same Platform
/// files and presented them in a window placed off the screen (macOS 27.2, 2026-11-10):
/// - a sheet given no size comes up as an empty strip 80 points tall, and a sheet draws no
///   toolbar item placed at `.navigation` or `.primaryAction` (PR 378's measurement);
/// - the chrome leaves a sheet that takes no Done bar, and one that sizes itself, pixel for
///   pixel as a bare `sheet` draws it;
/// - Return and Escape each close both the Participants sheet and the reader's Done bar;
/// - with the frame alone a sized sheet opened 470 points wide, or at its minimum width where
///   that is more (the reader 560 by 720). With its width fitted it opens at its ideal size
///   (the reader 760 by 720) and its window can be resized down to its minimum; the Contacts
///   sheet, which is not fitted, stays pixel for pixel as a bare `sheet` draws it.
/// Nobody has seen any of it in the app.
final class ChatDestinationMacSheetTests: XCTestCase {
    /// The Participants sheet is a `List` in a `NavigationStack`, which asks a Mac sheet for no
    /// size; unsized, it trapped the window behind a strip with no Done button.
    ///
    /// Revert-check: returning `.sizesItself` for `.participants` in
    /// `ChatDestination.macSheetChrome` makes this fail, and so does `.sizedWithDoneBar(.list)`
    /// (it has its own Done).
    func testMacSheetChrome_participants_isListSizeWithoutDoneBar() {
        XCTAssertEqual(ChatDestination.participants.macSheetChrome, .sized(.list))
    }

    /// The reader has no control of its own to close it: on iOS it is swiped down.
    ///
    /// Revert-check: returning `.sized(.reader)` for `.emailReader` in
    /// `ChatDestination.macSheetChrome` makes this fail.
    func testMacSheetChrome_emailReader_isReaderSizeWithDoneBar() throws {
        let destination = ChatDestination.emailReader(try makeReaderRoute())

        XCTAssertEqual(destination.macSheetChrome, .sizedWithDoneBar(.reader))
        XCTAssertTrue(destination.macSheetChrome.showsDoneBar)
    }

    /// Revert-check: returning `.sizesItself` for `.forwardCompose` in
    /// `ChatDestination.macSheetChrome` makes this fail, and so does `.sizedWithDoneBar(.compose)`
    /// (it has its own Cancel and Send).
    func testMacSheetChrome_forwardCompose_isComposeSizeWithoutDoneBar() {
        let destination = ChatDestination.forwardCompose(
            ComposeForwardModeContext(
                id: "forward",
                initialSubject: "Fwd: Hello",
                forwardedPlainTextBody: "Hello",
                forwardedHTMLBody: nil,
                forwardedInlineAttachmentInfos: [],
                forwardedRegularAttachments: []
            )
        )

        XCTAssertEqual(destination.macSheetChrome, .sized(.compose))
    }

    /// The Contacts sheet the Mac does present ("Create New Contact" in the Participants sheet).
    /// `OpenInContactsSheet` lays itself out and brings its own buttons, so a size forced on it
    /// would only stretch it, and a Done bar would give it a third button.
    ///
    /// Revert-check: returning `.sized(.list)` for `.addContact` in
    /// `ChatDestination.macSheetChrome` makes this fail.
    func testMacSheetChrome_addContact_sizesItself() {
        let destination = ChatDestination.addContact(ContactWrapper(contact: CNMutableContact()))

        XCTAssertEqual(destination.macSheetChrome, .sizesItself)
    }

    /// The Mac never presents this one (`ContactsSheet.supportsContactPicker` is false there);
    /// it is pinned so the two Contacts destinations cannot drift apart.
    ///
    /// Revert-check: returning `.sized(.list)` for `.contactPicker` in
    /// `ChatDestination.macSheetChrome` makes this fail.
    func testMacSheetChrome_contactPicker_sizesItself() {
        XCTAssertEqual(ChatDestination.contactPicker.macSheetChrome, .sizesItself)
    }

    /// The three forms a sheet's Mac chrome can take: only a sheet that sizes itself has no
    /// size, and it never takes the Done bar.
    ///
    /// Revert-check: making `MacSheetChrome.sizedWithDoneBar` pass `showsDoneBar: false` makes
    /// this fail, and so does giving `MacSheetChrome.sizesItself` a size.
    func testMacSheetChrome_forms_carryTheirSizeAndDoneBar() {
        XCTAssertEqual(MacSheetChrome.sized(.compose).size, .compose)
        XCTAssertFalse(MacSheetChrome.sized(.compose).showsDoneBar)
        XCTAssertEqual(MacSheetChrome.sizedWithDoneBar(.reader).size, .reader)
        XCTAssertTrue(MacSheetChrome.sizedWithDoneBar(.reader).showsDoneBar)
        XCTAssertNil(MacSheetChrome.sizesItself.size)
        XCTAssertFalse(MacSheetChrome.sizesItself.showsDoneBar)
    }

    /// A sheet with a size has its width fitted to its content, which is what opens it at its
    /// ideal width: the Mac offers every sheet 470 points, and the frame alone answered that or
    /// its minimum. A sheet that sizes itself must not be fitted: the Contacts sheet then
    /// opened 387 points wide instead of 470, and could be resized.
    ///
    /// Revert-check: making `MacSheetChrome.fitsIdealWidth` return `false` makes the first
    /// three assertions fail; making it return `true` makes the last fail.
    func testMacSheetChrome_fitsIdealWidth_onlyForASheetWithASize() {
        XCTAssertTrue(MacSheetChrome.sized(.list).fitsIdealWidth)
        XCTAssertTrue(MacSheetChrome.sized(.compose).fitsIdealWidth)
        XCTAssertTrue(MacSheetChrome.sizedWithDoneBar(.reader).fitsIdealWidth)
        XCTAssertFalse(MacSheetChrome.sizesItself.fitsIdealWidth)
    }

    /// `fitsIdealWidth` changes nothing unless the chrome hands it to the sheet's sizing, and
    /// the sizing it was measured with is this one: the system's, fitted in width only.
    /// `.fitted` is a different sizing: it drops the cap a short window puts on the height
    /// (the reader opened 720 points tall on a window 300 tall).
    ///
    /// HONEST SCOPE: this reads the Mac-only modifier's source, as `AppSheetSourceTests` reads
    /// the presenter's, because no test presents a sheet. It pins that the call is there, not
    /// what the system does with it. Fitting the height as well (`vertical: true`) measured the
    /// same as this in every window tried, and fails here all the same: a different sizing is
    /// to be measured again, not assumed.
    ///
    /// Revert-check: deleting the `.presentationSizing(` line from
    /// `MacSheetChromeModifier.body` makes this fail, and so does replacing its argument with
    /// `.fitted`.
    func testMacSheetChromeModifier_fitsTheSystemSizingInWidthOnlyWhereTheChromeSays() throws {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let modifierURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("esc-chatmail/Platform/MacSheetChromeModifier.swift")
        let code = try String(contentsOf: modifierURL, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined()
            .filter { !$0.isWhitespace }

        XCTAssertTrue(
            code.contains(".presentationSizing(.automatic.fitted(horizontal:chrome.fitsIdealWidth,vertical:false))"),
            "MacSheetChromeModifier must fit a sized sheet's width, or it opens 470 points wide or at its minimum width"
        )
    }

    /// Every preset must clear the 80-point strip an unsized sheet collapses to, or applying it
    /// would fix nothing.
    ///
    /// Revert-check: setting any preset's `minHeight` in `MacSheetSize` to 80 or less makes this
    /// fail.
    func testMacSheetSize_presets_openLargerThanTheirMinimumAndTheCollapsedStrip() {
        for size in [MacSheetSize.list, .compose, .reader] {
            XCTAssertGreaterThan(size.minHeight, 80)
            XCTAssertGreaterThanOrEqual(size.idealHeight, size.minHeight)
            XCTAssertGreaterThanOrEqual(size.idealWidth, size.minWidth)
        }
    }

    private func makeReaderRoute() throws -> EmailReaderRoute {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        var objectID: NSManagedObjectID?
        context.performAndWait {
            objectID = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context).objectID
        }
        return EmailReaderRoute(
            messageObjectID: try XCTUnwrap(objectID),
            conversationObjectID: nil,
            source: .previewCard,
            initialMode: .original
        )
    }
}
