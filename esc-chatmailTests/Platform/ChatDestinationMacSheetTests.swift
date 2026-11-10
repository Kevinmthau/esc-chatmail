import XCTest
import CoreData
@testable import esc_chatmail

/// Which Mac sheet size and close control each chat destination gets
/// (`ChatDestination+MacSheet`). The mapping is platform-neutral, so it is pinned here on iOS.
///
/// HONEST SCOPE: that a Mac sheet without a size comes up as an empty strip 80 points tall,
/// that it draws no toolbar item placed at `.navigation` or `.primaryAction`, and that the size
/// and the sheet placements fix both, was measured with a throwaway Mac program outside the
/// repo (macOS 27.2, 2026-11-10). No test presents a sheet: `ChatView` never mounts in the
/// unit-test host, so `macSheetSize(_:)`, `macSheetDoneBar(_:)` and the placements being
/// applied there are not exercised either.
final class ChatDestinationMacSheetTests: XCTestCase {
    /// The Participants sheet is a `List` in a `NavigationStack`, which asks a Mac sheet for no
    /// size; unsized, it trapped the window behind a strip with no Done button.
    ///
    /// Revert-check: returning nil for `.participants` in `ChatDestination.macSheetSize` makes
    /// this fail.
    func testMacSheetSize_participants_isListSize() {
        XCTAssertEqual(ChatDestination.participants.macSheetSize, .list)
        XCTAssertFalse(ChatDestination.participants.needsMacSheetDoneBar, "it has its own Done")
    }

    /// The reader has no control of its own to close it: on iOS it is swiped down.
    ///
    /// Revert-check: returning false for `.emailReader` in
    /// `ChatDestination.needsMacSheetDoneBar` makes this fail, and so does returning nil for it
    /// in `ChatDestination.macSheetSize`.
    func testMacSheet_emailReader_isReaderSizeWithDoneBar() throws {
        let destination = ChatDestination.emailReader(try makeReaderRoute())

        XCTAssertEqual(destination.macSheetSize, .reader)
        XCTAssertTrue(destination.needsMacSheetDoneBar)
    }

    /// Revert-check: returning nil for `.forwardCompose` in `ChatDestination.macSheetSize` makes
    /// this fail.
    func testMacSheetSize_forwardCompose_isComposeSize() {
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

        XCTAssertEqual(destination.macSheetSize, .compose)
        XCTAssertFalse(destination.needsMacSheetDoneBar, "it has its own Cancel and Send")
    }

    /// `OpenInContactsSheet` lays itself out and brings its own buttons, so a size forced on it
    /// would only stretch it.
    ///
    /// Revert-check: returning `.list` for `.contactPicker` in `ChatDestination.macSheetSize`
    /// makes this fail.
    func testMacSheet_contactPicker_sizesItselfAndHasItsOwnButtons() {
        XCTAssertNil(ChatDestination.contactPicker.macSheetSize)
        XCTAssertFalse(ChatDestination.contactPicker.needsMacSheetDoneBar)
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
