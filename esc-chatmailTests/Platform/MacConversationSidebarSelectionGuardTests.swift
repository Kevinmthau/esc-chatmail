#if os(macOS)
import AppKit
import CoreData
import SwiftUI
import XCTest
@testable import esc_chatmail

/// When the Mac sidebar turns off its list's own selection
/// (`MacSidebarListSelectionGuardView`). These run in `Mac.xctestplan` only: the list is an
/// `NSTableView` on the Mac alone.
///
/// Turning the selection off reloads the list's table. The sidebar used to leave it to the
/// first selected row's fill, so the reload came at the first click on a row, from inside
/// SwiftUI's drawing of that row, and the first native build logged a SwiftUI fault there
/// (build 528, 2026-11-12). The sidebar now has a guard behind its list as well, which does it
/// as the sidebar opens. What these pin is that it is done before any row is selected, and that
/// selecting the first row then writes nothing to the table.
///
/// HONEST SCOPE: the real sidebar over the real view model, in a window that is never on
/// screen, and not inside a split view. The fault itself needs a split view, and was measured
/// in a throwaway program and in the test host's log, where the first selection logged it
/// before this change and nothing after. These do not read the log: they pin that the write
/// which caused it is not made at the first selection. None of it has been seen in the app.
@MainActor
final class MacConversationSidebarSelectionGuardTests: XCTestCase {
    /// Kept for the length of a test: the rows' object IDs come from these stores.
    private var stacks: [TestCoreDataStack] = []

    override func tearDown() async throws {
        stacks = []
        try await super.tearDown()
    }

    /// Revert-check: deleting the `.background { MacSidebarListSelectionGuard()… }` from the
    /// list in `MacConversationSidebar.body` makes this fail: with no row selected nothing has
    /// turned the list's own selection off.
    func testSidebar_beforeAnyRowIsSelected_hasTurnedOffItsListsOwnSelection() async throws {
        let sidebar = try await mountSidebar(conversationCount: 12)

        let turnedOff = await waitUntil { sidebar.table.selectionHighlightStyle == .none }

        XCTAssertTrue(turnedOff, "The sidebar's list still draws a selection of its own")
        XCTAssertTrue(sidebar.table.selectedRowIndexes.isEmpty, "No row was selected to get it turned off")
    }

    /// The first selection is the moment the fault was logged at. The selected row's fill and
    /// the guard it carries are there, and the table's style is not written again.
    ///
    /// Revert-check: deleting the `.background { MacSidebarListSelectionGuard()… }` from the
    /// list in `MacConversationSidebar.body` makes this fail: the list's own selection is not
    /// off when the row is selected.
    func testSidebar_selectingItsFirstRow_writesNothingToTheTablesStyle() async throws {
        let sidebar = try await mountSidebar(conversationCount: 12)
        let turnedOff = await waitUntil { sidebar.table.selectionHighlightStyle == .none }
        XCTAssertTrue(turnedOff, "The sidebar's list still draws a selection of its own")
        let writes = StyleWrites(of: sidebar.table)

        // As a click on the row selects it.
        sidebar.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        // The fill is behind the row once its guard is in the row and has found the table.
        let filled = await waitUntil {
            sidebar.hostView.layoutSubtreeIfNeeded()
            return Self.guardView(inRow: 2, of: sidebar.table)?.guardedTableView === sidebar.table
        }
        XCTAssertTrue(filled, "The selected row never got its fill, so this pins nothing")
        // The turn that guard would have written on.
        await mainQueueTurn()
        XCTAssertEqual(writes.count, 0, "The table's selection style was written at the first selection")
        XCTAssertEqual(sidebar.table.selectionHighlightStyle, .none)
        XCTAssertEqual(sidebar.table.selectedRowIndexes, IndexSet(integer: 2), "The row is still selected")
    }

    // MARK: - The sidebar, mounted

    private static let firstDate = Date(timeIntervalSince1970: 1_768_000_000)

    private struct MountedSidebar {
        let hostView: NSView
        let table: NSTableView
    }

    private struct NoAbandonedActions: AbandonedPendingActionsManaging {
        func fetchAbandonedActions() async -> [AbandonedActionInfo] { [] }
        func retryAllAbandonedActions() async {}
        func dismissAllAbandonedActions() async {}
    }

    /// The selection is `@State` here, as it is in `MacMailboxView`.
    private struct SidebarHost: View {
        @ObservedObject var viewModel: ConversationListViewModel
        let abandonedActions: AbandonedPendingActionsModel
        let viewContext: NSManagedObjectContext
        @State private var selectedConversationIDs: Set<NSManagedObjectID> = []

        var body: some View {
            MacConversationSidebar(
                viewModel: viewModel,
                abandonedActions: abandonedActions,
                syncEngine: Dependencies.shared.syncEngine,
                selection: $selectedConversationIDs,
                currentUserEmail: "me@example.com",
                // Every conversation here is a mailing list, and a list's row asks the loader
                // for nothing (`ConversationRowPolicy.shouldLoadParticipantInfo`).
                participantLoader: ParticipantLoader(),
                viewContext: viewContext,
                onArchive: { _ in },
                onReportSpam: { _ in },
                onNewMessage: {}
            )
            .frame(width: 320, height: 700)
            .onAppear { viewModel.onAppear(in: viewContext) }
        }
    }

    /// Mailing-list conversations ten minutes apart, each with a message: the list's launch
    /// repair archives a conversation that has none.
    private func mountSidebar(conversationCount: Int) async throws -> MountedSidebar {
        let stack = TestCoreDataStack()
        stacks.append(stack)
        let viewContext = stack.makeMainQueueViewContext()
        for index in 0..<conversationCount {
            let date = Self.firstDate.addingTimeInterval(TimeInterval(-index * 600))
            let conversation = ConversationBuilder()
                .withDisplayName("Conversation \(index)")
                .withSnippet("Preview \(index)")
                .withLastMessageDate(date)
                .asList()
                .withListId("list\(index).example.com")
                .build(in: viewContext)
            _ = MessageBuilder()
                .withId("message-\(index)")
                .withDate(date)
                .inConversation(conversation)
                .build(in: viewContext)
        }
        try viewContext.save()

        let viewModel = ConversationListViewModel(
            dependencies: .forTesting(stack: stack, viewContext: viewContext)
        )
        let host = try mountInTestWindow(
            SidebarHost(
                viewModel: viewModel,
                abandonedActions: AbandonedPendingActionsModel(manager: NoAbandonedActions()),
                viewContext: viewContext
            )
        )
        addTeardownBlock { @MainActor in
            viewModel.onDisappear(preservePreviewRepair: false)
        }

        var found: NSTableView?
        let loaded = await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            found = Self.tableView(in: host.view)
            let count = viewModel.filteredConversationItems.count
            // Laid out as well as loaded: a table with no visible rect has made no rows.
            return count == conversationCount && found?.numberOfRows == count && found?.visibleRect.isEmpty == false
        }
        XCTAssertTrue(loaded, "The sidebar's list never loaded its rows")
        return MountedSidebar(
            hostView: host.view,
            table: try XCTUnwrap(found, "SwiftUI built no NSTableView for the sidebar's list")
        )
    }

    // MARK: - Helpers

    /// Counts the writes of a table's selection style, whatever they change, for as long as it
    /// lives.
    @MainActor
    private final class StyleWrites {
        private(set) var count = 0
        private var observation: NSKeyValueObservation?

        init(of table: NSTableView) {
            observation = table.observe(\.selectionHighlightStyle) { [weak self] _, _ in
                // KVO runs this inside the setter, on the setter's thread. A table's style is
                // set on the main thread; a write from anywhere else is not counted.
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    self?.count += 1
                }
            }
        }
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView {
            return tableView
        }
        for subview in view.subviews {
            if let tableView = tableView(in: subview) {
                return tableView
            }
        }
        return nil
    }

    /// The guard in a row's fill, if the row has one.
    private static func guardView(inRow row: Int, of table: NSTableView) -> MacSidebarListSelectionGuardView? {
        guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { return nil }
        return guardView(in: rowView)
    }

    private static func guardView(in view: NSView) -> MacSidebarListSelectionGuardView? {
        if let guardView = view as? MacSidebarListSelectionGuardView {
            return guardView
        }
        for subview in view.subviews {
            if let guardView = guardView(in: subview) {
                return guardView
            }
        }
        return nil
    }

    /// One turn of the main queue, which is what a guard waits before it writes. Blocks run in
    /// the order they were added, so a turn a guard asked for earlier has run by the time this
    /// returns.
    private func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Returns whether `condition` came true before the deadline.
    private func waitUntil(
        timeout: TimeInterval = 5,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return true
    }
}
#endif
