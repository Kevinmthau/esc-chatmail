import Foundation

/// Decides how a row of the Mac sidebar shows that it is selected: what the sidebar draws
/// behind it, and the colors the row draws on that (`MacConversationSidebar`;
/// `docs/mac-imessage-ui-plan.md`, PR 2 and decision 9).
///
/// The sidebar draws the selection itself and does not leave it to the list. A Mac list shows
/// its selection in the accent color only while the list has the keyboard focus. With the caret
/// in the reply field, which is where it is for most of the time a chat is open, the list's own
/// selection turns gray; in Messages the open conversation stays colored. A fill the row draws
/// covers the list's own exactly (measured off screen on macOS 27.2; "Spike results").
///
/// The fill and the row's colors come from one decision here, because each is wrong without the
/// other: white text on the list's gray selection cannot be read, and neither can dark text on
/// the accent color. `MacConversationSidebarSourceTests` pins that the sidebar takes both.
///
/// Pure, and compiled on both platforms like `MacSidebarSelectionPolicy`, so it is tested in the
/// iOS suite as well as `Mac.xctestplan`.
enum MacSidebarRowSelectionPolicy {
    /// What the sidebar draws behind a row.
    enum Fill: Equatable {
        /// The row is not selected: nothing, and the list's own row background shows.
        case none
        /// Selected, in a window the user is working in: the system accent color, whether or
        /// not the list has the keyboard focus.
        case accent
        /// Selected, in a window that is not active (another app is in front, or another
        /// window has the focus): the gray every Mac list shows there.
        case inactive
    }

    static func fill(isSelected: Bool, windowAppearsActive: Bool) -> Fill {
        guard isSelected else { return .none }
        return windowAppearsActive ? .accent : .inactive
    }

    /// Which of a selected row's neighbors are selected too. The fill is square at an edge it
    /// shares with another selected row and rounded at one it does not.
    ///
    /// A Mac list draws selected rows that touch as one shape, rounded only at its ends, and
    /// that shape is still there under the sidebar's fills. A fill rounded at all four corners
    /// would let it show at the corners between two selected rows: gray notches in the accent
    /// color whenever the list does not have the keyboard focus (seen in an off-screen drawing
    /// of the row on macOS 27.2).
    struct Joins: Equatable {
        var above = false
        var below = false

        static let none = Joins()
    }

    /// The joins of every selected row that has one, by row. Empty when fewer than two rows are
    /// selected, which is nearly always: then no row is looked at.
    ///
    /// `orderedIDs` is the list's rows from top to bottom. A selected row the list is not
    /// showing (hidden by a search or a filter) joins nothing.
    static func joins<IDs: Sequence>(
        orderedIDs: IDs,
        selection: Set<IDs.Element>
    ) -> [IDs.Element: Joins] where IDs.Element: Hashable {
        guard selection.count > 1 else { return [:] }

        var joins: [IDs.Element: Joins] = [:]
        var previousSelectedID: IDs.Element?
        for id in orderedIDs {
            guard selection.contains(id) else {
                previousSelectedID = nil
                continue
            }
            if let previousSelectedID {
                joins[previousSelectedID, default: .none].below = true
                joins[id, default: .none].above = true
            }
            previousSelectedID = id
        }
        return joins
    }

    /// The row's colors on `fill`. Only the accent color needs light text: the inactive gray is
    /// light in a light window and dark in a dark one, as the list's background is, so the
    /// standard colors read on it.
    static func palette(on fill: Fill) -> ConversationRowPalette {
        switch fill {
        case .accent:
            return .onSelectionFill
        case .none, .inactive:
            return .standard
        }
    }
}
