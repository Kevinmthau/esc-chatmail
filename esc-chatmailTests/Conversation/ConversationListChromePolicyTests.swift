import XCTest
@testable import esc_chatmail

final class ConversationListChromePolicyTests: XCTestCase {
    private typealias Policy = ConversationListChromePolicy

    func testNavigationTitle_notSelecting_returnsChats() {
        XCTAssertEqual(Policy.navigationTitle(isSelecting: false, selectedCount: 0), "Chats")
        XCTAssertEqual(Policy.navigationTitle(isSelecting: false, selectedCount: 3), "Chats")
    }

    func testNavigationTitle_selecting_returnsSelectedCount() {
        XCTAssertEqual(Policy.navigationTitle(isSelecting: true, selectedCount: 0), "0 Selected")
        XCTAssertEqual(Policy.navigationTitle(isSelecting: true, selectedCount: 2), "2 Selected")
    }

    /// Select sits in the top-leading corner and becomes Cancel in place, so
    /// the button that entered selection mode is the one that leaves it.
    func testLeadingButtonTitle_selectionMode_togglesBetweenSelectAndCancel() {
        XCTAssertEqual(Policy.leadingButtonTitle(isSelecting: false), "Select")
        XCTAssertEqual(Policy.leadingButtonTitle(isSelecting: true), "Cancel")
    }

    /// The filter menu owns the top-trailing corner outside selection mode,
    /// whatever the counts.
    func testTrailingItem_notSelecting_returnsFilterMenu() {
        XCTAssertEqual(Policy.trailingItem(isSelecting: false, selectedCount: 0, visibleCount: 0), .filterMenu)
        XCTAssertEqual(Policy.trailingItem(isSelecting: false, selectedCount: 0, visibleCount: 5), .filterMenu)
    }

    func testTrailingItem_selectingWithPartialSelection_returnsEnabledSelectAll() {
        XCTAssertEqual(
            Policy.trailingItem(isSelecting: true, selectedCount: 0, visibleCount: 5),
            .selectAll(title: "Select All", isEnabled: true)
        )
        XCTAssertEqual(
            Policy.trailingItem(isSelecting: true, selectedCount: 2, visibleCount: 5),
            .selectAll(title: "Select All", isEnabled: true)
        )
    }

    func testTrailingItem_selectingWithEveryVisibleRowSelected_returnsDeselectAll() {
        XCTAssertEqual(
            Policy.trailingItem(isSelecting: true, selectedCount: 5, visibleCount: 5),
            .selectAll(title: "Deselect All", isEnabled: true)
        )
    }

    /// The old inline check compared counts alone, so an empty list (0 == 0)
    /// offered "Deselect All" with nothing selected.
    ///
    /// Revert-check: dropping the `selectedCount > 0` guard in
    /// `ConversationListChromePolicy.trailingItem` makes this fail.
    func testTrailingItem_selectingEmptyList_returnsDisabledSelectAll() {
        XCTAssertEqual(
            Policy.trailingItem(isSelecting: true, selectedCount: 0, visibleCount: 0),
            .selectAll(title: "Select All", isEnabled: false)
        )
    }

    func testBottomBar_notSelecting_returnsSearchAndCompose() {
        XCTAssertEqual(Policy.bottomBar(isSelecting: false, selectedCount: 0), .searchAndCompose)
    }

    /// Entering selection mode keeps search and compose until a row is picked;
    /// an Archive/Spam bar with nothing selected would act on nothing.
    func testBottomBar_selectingWithNoSelection_returnsSearchAndCompose() {
        XCTAssertEqual(Policy.bottomBar(isSelecting: true, selectedCount: 0), .searchAndCompose)
    }

    func testBottomBar_selectingWithSelection_returnsSelectionActions() {
        XCTAssertEqual(Policy.bottomBar(isSelecting: true, selectedCount: 1), .selectionActions)
    }
}
