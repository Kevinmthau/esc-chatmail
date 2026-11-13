import XCTest
@testable import esc_chatmail

/// The Mac sidebar's selection rules. The policy is generic over the row's identifier, so these
/// run on plain integers, in the iOS suite and in `Mac.xctestplan`.
final class MacSidebarSelectionPolicyTests: XCTestCase {
    private typealias Policy = MacSidebarSelectionPolicy

    // MARK: - Detail

    func testDetail_emptySelection_showsThePlaceholder() {
        XCTAssertEqual(Policy.detail(for: Set<Int>()), .placeholder)
    }

    func testDetail_oneRowSelected_showsThatConversation() {
        XCTAssertEqual(Policy.detail(for: [7]), .conversation(7))
    }

    /// Revert-check: returning `.conversation(selection.first!)` for every non-empty selection
    /// in `MacSidebarSelectionPolicy.detail` makes this fail; a Shift-click would then open
    /// (and mark read) an arbitrary one of the selected chats.
    func testDetail_severalRowsSelected_showsTheirCountNotAChat() {
        XCTAssertEqual(Policy.detail(for: [1, 2, 3]), .multiple(count: 3))
    }

    // MARK: - Action targets

    /// Revert-check: returning `requested` from `MacSidebarSelectionPolicy.actionTargets` makes
    /// this fail. Delete would then archive a chat whose row a search is hiding.
    func testActionTargets_selectionHoldsAHiddenConversation_actsOnlyOnVisibleRows() {
        XCTAssertEqual(Policy.actionTargets(requested: [1, 2, 9], visibleIDs: [1, 2, 3]), [1, 2])
        XCTAssertEqual(Policy.actionTargets(requested: [9], visibleIDs: [1, 2, 3]), [])
    }

    // MARK: - Mark as Read / Mark as Unread

    /// The open chat stays in the chat column while a search hides its row, and the command is
    /// about the chat in front of the user.
    ///
    /// Revert-check: returning `Set(visibleIDs.filter(selection.contains))` for every selection
    /// from `MacSidebarSelectionPolicy.readStateTargets` makes this fail: Command-Shift-U would
    /// be disabled with a chat open.
    func testReadStateTargets_oneSelectedConversation_isTheTarget_listedOrNot() {
        XCTAssertEqual(Policy.readStateTargets(selection: [9], visibleIDs: [1, 2, 3]), [9])
        XCTAssertEqual(Policy.readStateTargets(selection: [2], visibleIDs: [1, 2, 3]), [2])
    }

    /// Revert-check: returning `selection` for every selection from
    /// `MacSidebarSelectionPolicy.readStateTargets` makes this fail: the command would change
    /// rows the user cannot see, which Delete does not.
    func testReadStateTargets_severalSelected_areTheRowsTheListShows() {
        XCTAssertEqual(Policy.readStateTargets(selection: [1, 2, 9], visibleIDs: [1, 2, 3]), [1, 2])
        XCTAssertEqual(Policy.readStateTargets(selection: [8, 9], visibleIDs: [1, 2, 3]), [])
    }

    func testReadStateTargets_nothingSelected_isEmpty() {
        XCTAssertEqual(Policy.readStateTargets(selection: Set<Int>(), visibleIDs: [1, 2, 3]), [])
    }

    // MARK: - After a list action

    /// Revert-check: returning `remaining` (the empty set) at the end of
    /// `MacSidebarSelectionPolicy.selectionAfterListAction` makes this fail; Delete would then
    /// leave nothing selected and the next arrow key would jump to the top of the list.
    func testSelectionAfterListAction_selectedRowArchived_movesToTheNextRow() {
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [2], actedOn: [2], orderedVisibleIDs: [1, 2, 3, 4]),
            [3]
        )
    }

    func testSelectionAfterListAction_lastRowArchived_movesToTheRowBefore() {
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [4], actedOn: [4], orderedVisibleIDs: [1, 2, 3, 4]),
            [3]
        )
    }

    func testSelectionAfterListAction_onlyRowArchived_selectsNothing() {
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [1], actedOn: [1], orderedVisibleIDs: [1]),
            []
        )
    }

    /// The replacement is the row after the *last* removed row, skipping removed rows between.
    func testSelectionAfterListAction_severalSelectedRowsArchived_movesPastAllOfThem() {
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [2, 4], actedOn: [2, 4], orderedVisibleIDs: [1, 2, 3, 4, 5]),
            [5]
        )
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [3, 4], actedOn: [3, 4], orderedVisibleIDs: [1, 2, 3, 4]),
            [2]
        )
    }

    /// A right-click on a row that is not selected archives that row; the open chat stays.
    ///
    /// Revert-check: removing the `isDisjoint` guard in
    /// `MacSidebarSelectionPolicy.selectionAfterListAction` makes the second assertion fail:
    /// with nothing selected, archiving a row from its context menu would select (and mark
    /// read) the row after it.
    func testSelectionAfterListAction_unselectedRowArchived_keepsTheSelection() {
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [1], actedOn: [3], orderedVisibleIDs: [1, 2, 3, 4]),
            [1]
        )
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [], actedOn: [3], orderedVisibleIDs: [1, 2, 3, 4]),
            []
        )
    }

    /// Rows that were selected but not acted on stay; no neighbour is added to them.
    func testSelectionAfterListAction_partOfTheSelectionArchived_keepsTheRest() {
        XCTAssertEqual(
            Policy.selectionAfterListAction(selection: [1, 2, 3], actedOn: [2], orderedVisibleIDs: [1, 2, 3, 4]),
            [1, 3]
        )
    }

    // MARK: - After the chat closes itself

    /// Revert-check: making `MacSidebarSelectionPolicy.selectionAfterChatExit` return `selection`
    /// unchanged makes this fail: a chat that archived itself would stay open.
    func testSelectionAfterChatExit_openChatExits_selectsNothing() {
        XCTAssertEqual(Policy.selectionAfterChatExit(selection: [2], exited: 2), [])
    }

    /// A deferred exit can land after the user has moved on (`ChatConversationExitActionPolicy`);
    /// it must not close the chat they moved to.
    func testSelectionAfterChatExit_anotherChatIsOpenByThen_keepsIt() {
        XCTAssertEqual(Policy.selectionAfterChatExit(selection: [5], exited: 2), [5])
    }

    // MARK: - After the list changes

    /// Revert-check: replacing the filter in `MacSidebarSelectionPolicy.selectionAfterListChange`
    /// with `selection.intersection(visibleIDs)` (what `ConversationSelectionService
    /// .retainSelection` does for iOS's select mode) makes this fail: typing in the search field
    /// would close the chat being read.
    func testSelectionAfterListChange_rowHiddenBySearchButStillOpenable_staysSelected() {
        XCTAssertEqual(
            Policy.selectionAfterListChange(selection: [2], visibleIDs: [1, 3], isOpenable: { _ in true }),
            [2]
        )
    }

    /// Revert-check: returning `selection` unchanged from `selectionAfterListChange` makes this
    /// fail: a chat archived from another device would stay open with no row in the list.
    func testSelectionAfterListChange_rowGoneAndNoLongerOpenable_leavesTheSelection() {
        XCTAssertEqual(
            Policy.selectionAfterListChange(selection: [2], visibleIDs: [1, 3], isOpenable: { _ in false }),
            []
        )
    }

    /// A row the list still shows is never asked about, and never dropped.
    func testSelectionAfterListChange_rowStillListed_staysWithoutAskingWhetherItIsOpenable() {
        var asked: [Int] = []
        let result = Policy.selectionAfterListChange(selection: [1, 2], visibleIDs: [1, 3]) { id in
            asked.append(id)
            return false
        }
        XCTAssertEqual(result, [1])
        XCTAssertEqual(asked, [2])
    }
}
