import Foundation

/// Decides the conversation list's chrome — the navigation title, the two
/// top-corner items, and which bar sits along the bottom — from the selection
/// state, so `ConversationListView`'s body stays declarative.
///
/// The layout follows iOS 26 Messages: Select (Cancel while selecting) in the
/// top-leading corner, the filter menu in the top-trailing corner (Select All
/// while selecting), and search plus compose across the bottom. There is no
/// in-app settings button; the account and Sign Out live in the Settings app
/// (`SettingsAppPreferences`).
enum ConversationListChromePolicy {
    enum TrailingItem: Equatable {
        case filterMenu
        case selectAll(title: String, isEnabled: Bool)
    }

    enum BottomBar: Equatable {
        case searchAndCompose
        case selectionActions
    }

    static func navigationTitle(isSelecting: Bool, selectedCount: Int) -> String {
        isSelecting ? "\(selectedCount) Selected" : "Chats"
    }

    static func leadingButtonTitle(isSelecting: Bool) -> String {
        isSelecting ? "Cancel" : "Select"
    }

    /// "Deselect All" only when something is selected and it is every visible
    /// row — what `ConversationSelectionService.selectAll` will clear on tap
    /// (the selection is always a subset of the visible rows, so equal counts
    /// mean equal sets). The old inline check compared counts alone, so an
    /// empty list (0 == 0) offered "Deselect All"; with no rows there is
    /// nothing to select, so the button is disabled instead.
    static func trailingItem(isSelecting: Bool, selectedCount: Int, visibleCount: Int) -> TrailingItem {
        guard isSelecting else { return .filterMenu }
        let tapClearsSelection = selectedCount > 0 && selectedCount == visibleCount
        return .selectAll(
            title: tapClearsSelection ? "Deselect All" : "Select All",
            isEnabled: visibleCount > 0
        )
    }

    /// The Archive/Spam bar replaces search and compose only once something is
    /// selected; with an empty selection it would have nothing to act on.
    static func bottomBar(isSelecting: Bool, selectedCount: Int) -> BottomBar {
        isSelecting && selectedCount > 0 ? .selectionActions : .searchAndCompose
    }
}
