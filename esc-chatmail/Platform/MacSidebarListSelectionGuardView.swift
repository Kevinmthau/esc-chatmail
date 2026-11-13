#if os(macOS)
import AppKit

/// Stops the list this view belongs to drawing its own selection (`MacSidebarListSelectionGuard`).
///
/// The sidebar draws a selected row's fill itself (`MacSidebarRowSelectionPolicy`). Behind a
/// SwiftUI `List` on the Mac is an `NSTableView`, and it draws a selection of its own under
/// that fill: gray whenever the list does not have the keyboard focus. The fill has the same
/// shape, so it covers it, but only on a system whose table draws that shape, and the shape is
/// not something the app is told. It was measured, on one system. This view finds the list's
/// table and sets its `selectionHighlightStyle` to `.none`, AppKit's setting for a table that
/// draws no selection. The rows are selected as before: the style changes what the table draws,
/// not what it selects.
///
/// The sidebar has this view in two places: behind its list, and in every selected row's fill.
/// Where it is and when it writes both follow from what the write does to the table.
///
/// What the write does. Measured 2026-11-12 on macOS 27.2, not in the app. First in a throwaway
/// program with the table's style setter hooked: an `.inset` `List(selection:)` with the
/// sidebar's fill, its rows identified by a struct and the `ForEach` given the row and nothing
/// around it, alone in a window and as the sidebar of a `NavigationSplitView`, in windows that
/// could not be seen. Then with the real sidebar in the Mac test host.
/// - The setter is not a flag. It reloads the table (`_reloadTableForStyleDataChange`): every
///   row view is thrown away, the selected rows are selected again, and that calls the list's
///   delegate, which writes the list's selection binding once more. In a split view the rows
///   were built again before the setter returned.
/// - A guard in a selected row's fill is first laid out while SwiftUI is rendering that row,
///   and the guard used to write right there, in `layout()`. In a split view, which is where
///   the sidebar is, SwiftUI then logged the fault "NSHostingView is being laid out reentrantly
///   while rendering its SwiftUI content. This is not supported and the current layout pass
///   will be skipped", at the first selection, every time it was tried: the row being rendered
///   was among the rows built again. With the list alone in its window nothing was logged. A
///   build of the app with the table's calls logged had the fault 34 ms after the guard's
///   write, at the first click on a row.
/// - Made on the next turn of the main queue, the same write logged no fault. On a list of 220
///   rows or more it still logged AppKit's "Application performed a reentrant operation in its
///   NSTableView delegate. This warning will become an assert in the future", and so did a
///   write made with no row selected: on a list that long, building the rows again is what
///   AppKit warns about, from wherever the write is made. SwiftUI's own first load of that many
///   rows logs it too. With 200 rows and fewer the write logged nothing.
/// - Written while the list had no rows, there was nothing to build again and nothing was
///   logged. The style was still `.none` after the rows arrived and after every selection.
///
/// So the write is made early, and never from inside a layout.
/// - `MacConversationSidebar` has a guard behind its list. It finds the table as the sidebar
///   opens, with no row selected and, in the app, the rows yet to load, and writes then. At the
///   first selection nothing is left to write, and neither message was logged there: with 27,
///   230 and 500 rows, selected from the table and from the binding. With the real sidebar and
///   27 and 300 conversations in a split view, the guard in the fill alone had logged the
///   fault at four first selections of four, and the warning at both with 300.
/// - `MacSidebarRowSelectionBackground` still carries a guard in every selected row's fill. It
///   has a write to make only where the table still draws a selection when a row is selected:
///   a list with no guard behind it, or one whose guard found nothing.
/// - Neither writes from `layout()`, or from any other call AppKit or SwiftUI makes into the
///   view. Those calls look for the table, and leave a write to the next turn of the main
///   queue (`scheduleTurnOff`).
///
/// Where the table is, in the same measurements.
/// - The list is an `NSTableView` (a `SwiftUIOutlineListView`), and a view in a row's
///   `listRowBackground` is inside it, four superviews down. The view is not inside it yet when
///   it joins its window or its superview: `layout()` is the call that found the table.
/// - A view in the list's own `background` is never inside the table. The two are drawn by one
///   `NSHostingView`, in a split view the sidebar column's, which is this view's second
///   superview. The table is under that, in a scroll view drawn over this view. The list's
///   views join the window after its background's, so the table was first there to find at
///   this view's second `layout()`.
/// - SwiftUI never set the style back: not when a row's content changed, the selection changed
///   or was emptied, every row was replaced, a row moved, the rows loaded into an empty list,
///   or the list was resized, scrolled, disabled, or switched between light and dark. So this
///   is an assignment, looked at again at each `layout()` in case something does undo it, and
///   not an observation as in `MacSidebarCollapseGuardView`.
///
/// Two bounds, for what the measurements did not show and nothing promises.
/// - The guard behind the list finds no table when it joins the window, and none on its turn
///   of the main queue if the list's views have still not joined by then. A second `layout()`
///   found it in the measurements, but a view with no size is owed no second `layout()`. So a
///   turn that finds no table looks again, a few times over about three seconds
///   (`standardLaterLookDelays`), and then stops: a system that builds a list another way has
///   no table to find, and each look searches the window's views. Any call from the list starts
///   the looking over.
/// - The table kept `.none` through everything tried. If a system's table does not keep it,
///   each write reloads the table, the reload builds the selected row's fill again, and the
///   guard in the new fill finds the style set back and writes again: a reload at every turn
///   for as long as a row is selected. So one table's style is written `tableWriteLimit` times
///   and no more, by however many guards, and after that the table draws its own selection
///   under the fill, as it did before this view. The count is the table's, not a guard's: the
///   guard in a fill is a new view after every reload.
///
/// What is left. A sidebar that opens with 220 rows or more already loaded gets AppKit's
/// warning once as it opens, from the reload, beside the one SwiftUI's own load of those rows
/// logs. The app's sidebar opens empty: `MacMailboxView` builds the list's view model with the
/// view. And a fill in a list with no guard behind it still reloads the table at the first
/// selection, a turn of the main queue later.
///
/// The style is never set back to the table's own. The sidebar draws a fill for every selected
/// row for as long as the list lives, so the list has no selection of its own to go back to.
///
/// Not seen: the ring a table draws around a right-clicked row while its menu is open. Asking
/// the table for the row's menu drew no ring in the program with the style either way, so the
/// program cannot say whether `.none` changes it.
///
/// HONEST SCOPE: this depends on how SwiftUI builds a list on macOS 27.2, which is not API, and
/// nothing here was run on macOS 26, the oldest system the app runs on. If a system builds a
/// list another way, `guardedTableView` stays nil, the list goes on drawing its own selection,
/// and the fill covers it wherever the two have the same shape, which is what the sidebar had
/// before this view. `MacSidebarRowSelectionBackgroundTests` and
/// `MacConversationSidebarSelectionGuardTests` mount real lists, so on the system the Mac tests
/// run on, a change in how a list is built fails a test. None of it has been seen in the app.
final class MacSidebarListSelectionGuardView: NSView {
    /// How many times one table's style is written, by all the guards that find it. The first
    /// write is the one the measurements needed. The others are for a style something set back
    /// once or twice; a table that sets it back every time is left alone after them.
    static let tableWriteLimit = 3

    /// How long each look for a table waits after the one before found none, the first of them
    /// after the guard's turn of the main queue. About three seconds in all.
    static let standardLaterLookDelays: [TimeInterval] = [0.05, 0.1, 0.2, 0.4, 0.8, 1.6]

    /// The table this view found for its list, or nil while it has found none. Its own
    /// selection is off from the turn of the main queue after it was found.
    private(set) weak var guardedTableView: NSTableView?
    /// Whether a turn of the main queue is already waiting to turn the table's selection off.
    private var isTurnOffScheduled = false
    /// `standardLaterLookDelays`, except in a test that cannot wait three seconds.
    var laterLookDelays = MacSidebarListSelectionGuardView.standardLaterLookDelays
    /// How many later looks have been asked for since the list last called.
    private var laterLooksMade = 0
    /// Whether a later look is waiting.
    private var isLaterLookPending = false
    /// Tells a later look that is still waiting from one that was called off.
    private var laterLookGeneration = 0

    /// Whether this view is still going to look for its table, or write to it, without another
    /// call from the list.
    var isLookPending: Bool {
        isTurnOffScheduled || isLaterLookPending
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guardListTableView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guardListTableView()
    }

    /// The call that found the table in the measurements, from either place.
    override func layout() {
        super.layout()
        guardListTableView()
    }

    /// The guard is not part of the interface. It has no size where the sidebar puts it, and
    /// this keeps a click from landing on it at any size.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Finds the list's table and, unless its own selection is already off, has it turned off
    /// on the next turn of the main queue.
    ///
    /// Never here. AppKit and SwiftUI call this while they lay the list out, and the write
    /// reloads the table.
    func guardListTableView() {
        let tableView = listTableView()
        guardedTableView = tableView
        if let tableView, !Self.needsTurnOff(tableView) {
            // Found, with nothing to write: nothing is left to look for.
            callOffLaterLook()
            return
        }
        // Also with no table found: a list's views join the window after its background's, so
        // the table may be there a turn from now and not before.
        scheduleTurnOff()
    }

    /// One turn of the main queue, however many calls ask for it before it runs.
    private func scheduleTurnOff() {
        // The list called, so what a later look was waiting for may be here: the turn looks
        // now, and the later looks start over after it.
        callOffLaterLook()
        laterLooksMade = 0
        guard !isTurnOffScheduled else { return }
        isTurnOffScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTurnOffScheduled = false
            self.turnOffListTableViewSelection()
        }
    }

    /// The write, on a turn of the main queue of its own. The table is looked for again: this
    /// view may have left its list since the turn was asked for, or its list's table may have
    /// joined the window.
    private func turnOffListTableViewSelection() {
        let tableView = listTableView()
        guardedTableView = tableView
        guard let tableView else {
            scheduleLaterLook()
            return
        }
        // Only a change is written: the setter reloads the table.
        guard Self.needsTurnOff(tableView) else { return }
        // Counted before it is made. The setter builds the rows again before it returns, and a
        // guard in one of them reads the count.
        let writesMade = Self.writesMade(to: tableView) + 1
        objc_setAssociatedObject(tableView, Self.writeCountKey, writesMade, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if writesMade == Self.tableWriteLimit {
            Log.warning(
                "Mac sidebar: the list's table does not keep its selection style off; this write is the last",
                category: .ui
            )
        }
        tableView.selectionHighlightStyle = .none
    }

    /// Another look for the table, later, after a turn that found none.
    ///
    /// Not for a guard in no window, which has no list to wait for: a fill's guard is in none
    /// when it joins its superview, and `layout()` finds its table. And not after the last of
    /// `laterLookDelays`, until the list calls again.
    private func scheduleLaterLook() {
        guard window != nil, let delay = laterLookDelays.dropFirst(laterLooksMade).first else { return }
        laterLooksMade += 1
        laterLookGeneration += 1
        let generation = laterLookGeneration
        isLaterLookPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isLaterLookPending, self.laterLookGeneration == generation else { return }
            self.isLaterLookPending = false
            self.turnOffListTableViewSelection()
        }
    }

    private func callOffLaterLook() {
        isLaterLookPending = false
        laterLookGeneration += 1
    }

    /// Whether a guard still has a write to make to `tableView`: it draws a selection of its
    /// own, and the guards have not written its style `tableWriteLimit` times already.
    private static func needsTurnOff(_ tableView: NSTableView) -> Bool {
        tableView.selectionHighlightStyle != .none && writesMade(to: tableView) < tableWriteLimit
    }

    /// How many times guards have written `tableView`'s style. Kept on the table, so it is
    /// every guard's count and goes when the table does.
    private static func writesMade(to tableView: NSTableView) -> Int {
        (objc_getAssociatedObject(tableView, writeCountKey) as? Int) ?? 0
    }

    /// Identifies the count among a table's associated objects, by address only.
    private static let writeCountKey = UnsafeRawPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    )

    /// The table of the list this view belongs to: the one it is inside, which is where a
    /// row's background is, or else the one drawn over it, which is where a list is from its
    /// own background.
    private func listTableView() -> NSTableView? {
        enclosingTableView() ?? tableViewDrawnOverThisView()
    }

    private func enclosingTableView() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? NSTableView {
                return tableView
            }
            ancestor = view.superview
        }
        return nil
    }

    /// Looks under each ancestor in turn, nearest first, for a table that is drawn over this
    /// view. In the measurements the second ancestor had it.
    ///
    /// Drawn over this view, and not just the nearest table: until the list's views have joined
    /// the window the search goes on up to the window's top, and a table found up there could be
    /// another list's. Turning that one's selection off would be seen in that list, far from
    /// here.
    private func tableViewDrawnOverThisView() -> NSTableView? {
        var searched: NSView = self
        var ancestor = superview
        while let view = ancestor {
            if let tableView = Self.tableView(under: view, skipping: searched, drawnOver: self) {
                return tableView
            }
            searched = view
            ancestor = view.superview
        }
        return nil
    }

    private static func tableView(
        under view: NSView,
        skipping searched: NSView,
        drawnOver guardView: NSView
    ) -> NSTableView? {
        for subview in view.subviews where subview !== searched {
            if let tableView = subview as? NSTableView {
                if isDrawn(tableView, over: guardView) {
                    return tableView
                }
                // A table's own views are its rows. No other list is looked for in there.
                continue
            }
            if let tableView = tableView(under: subview, skipping: searched, drawnOver: guardView) {
                return tableView
            }
        }
        return nil
    }

    /// Whether the list `tableView` is the table of covers `guardView`'s middle. A list's table
    /// scrolls, so the area the list takes is its scroll view's.
    private static func isDrawn(_ tableView: NSTableView, over guardView: NSView) -> Bool {
        let listArea: NSView = tableView.enclosingScrollView ?? tableView
        let middle = NSPoint(x: guardView.bounds.midX, y: guardView.bounds.midY)
        return listArea.bounds.contains(listArea.convert(middle, from: guardView))
    }
}
#endif
