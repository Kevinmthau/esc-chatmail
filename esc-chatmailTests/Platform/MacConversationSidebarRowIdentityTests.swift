#if os(macOS)
import AppKit
import Combine
import CoreData
import SwiftUI
import XCTest
@testable import esc_chatmail

/// What a Mac list draws after one of its rows moves, by what its rows are identified with
/// (`MacSidebarRowID`). These run in `Mac.xctestplan` only: the fault is in the `NSTableView`
/// behind a SwiftUI `List` on the Mac.
///
/// Every test here compares two drawings of a list's table: the list that was on screen while a
/// row moved, and a list mounted afterwards with the rows already in their new order. A list
/// that follows its data draws the same thing both ways.
///
/// HONEST SCOPE: the lists are in a window that is never on screen, and the drawings are taken
/// with `cacheDisplay`, so this pins what the table draws there on the system the tests run on.
/// The first native build showed the same fault on screen (build 528, 2026-11-12); the fix has
/// not been seen in the app.
@MainActor
final class MacConversationSidebarRowIdentityTests: XCTestCase {
    /// Kept for the length of a test: the rows' object IDs come from these stores.
    private var stacks: [TestCoreDataStack] = []

    override func tearDown() async throws {
        stacks = []
        try await super.tearDown()
    }

    // MARK: - The system's behavior, in a list of this file's own

    /// The reason `MacSidebarRowID` exists. Identified by `NSManagedObjectID`, a list keeps
    /// drawing rows at the positions they had before the move.
    ///
    /// If this fails, a system has started drawing moved rows where they belong with object
    /// IDs, and the struct has nothing left to work around. Until then it shows that the
    /// comparison the other tests rely on does catch the fault.
    func testList_withRowsIdentifiedByObjectIDs_drawsStaleRowsAfterARowMoves() async throws {
        let rows = try makeRows(count: 40)
        let moved = Self.moving(rows, from: 13, to: 0)
        let model = Rows(rows)
        let table = try await tableOfMounted(ObjectIDList(model: model), rowCount: rows.count)
        let fresh = try await tableOfMounted(ObjectIDList(model: Rows(moved)), rowCount: rows.count)
        let before = try XCTUnwrap(drawing(of: table))
        let expected = try XCTUnwrap(drawing(of: fresh))
        XCTAssertNotEqual(before, expected, "The move changes nothing a list draws, so this compares nothing")

        model.rows = moved

        let redrew = await waitUntil { self.drawing(of: table) != before }
        XCTAssertTrue(redrew, "The list never drew the move at all")
        let followed = await waitUntil(timeout: 1.5) { self.drawing(of: table) == self.drawing(of: fresh) }
        attach(drawing(of: table), named: "object-ids-after-the-move")
        attach(expected, named: "object-ids-fresh")
        XCTAssertFalse(
            followed,
            "A list identified by NSManagedObjectID now draws a moved row where a fresh list does; MacSidebarRowID may no longer be needed"
        )
    }

    /// The same list, with each object ID inside a `MacSidebarRowID`: the id the sidebar gives
    /// its rows is one the list follows.
    ///
    /// Revert-check: the test above is this one's, run every time. It is the same list with the
    /// object ID itself as each row's id, and there the comparison fails.
    func testList_withRowsIdentifiedBySidebarRowIDs_drawsAMovedRowWhereAFreshListDoes() async throws {
        let rows = try makeRows(count: 40)
        let moved = Self.moving(rows, from: 13, to: 0)
        let model = Rows(rows)
        let table = try await tableOfMounted(RowIDList(model: model), rowCount: rows.count)
        let fresh = try await tableOfMounted(RowIDList(model: Rows(moved)), rowCount: rows.count)
        let before = try XCTUnwrap(drawing(of: table))
        let expected = try XCTUnwrap(drawing(of: fresh))
        XCTAssertNotEqual(before, expected, "The move changes nothing a list draws, so this compares nothing")

        model.rows = moved

        let followed = await waitUntil { self.drawing(of: table) == self.drawing(of: fresh) }
        attach(drawing(of: table), named: "row-ids-after-the-move")
        attach(expected, named: "row-ids-fresh")
        XCTAssertTrue(followed, "The list did not draw the moved row where a fresh list draws it")
    }

    // MARK: - The sidebar

    /// The fault the first native build had: after a sync moved a conversation to the top, the
    /// sidebar drew other conversations in the rows above its old place.
    ///
    /// Revert-check: giving the rows back their object IDs in `MacConversationSidebar.body`
    /// (`ForEach(viewModel.filteredConversationItems) { item in`, with the list's selection and
    /// the context menu's type changed to match) makes this fail.
    func testSidebar_afterAConversationMovesToTheTop_drawsWhatAFreshlyOpenedSidebarDraws() async throws {
        let mailbox = try makeMailbox(conversationCount: 40)
        let sidebar = try await mountSidebar(over: mailbox)
        let before = try XCTUnwrap(drawing(of: sidebar.table))

        // Mail arrives in the conversation at row 13: it is now the newest.
        let movedID = sidebar.viewModel.filteredConversationItems[13].id
        let conversation = try XCTUnwrap(try mailbox.viewContext.existingObject(with: movedID) as? Conversation)
        conversation.lastMessageDate = Self.firstDate.addingTimeInterval(86_400)
        conversation.snippet = "new mail"
        try mailbox.viewContext.save()
        let published = await waitUntil { sidebar.viewModel.filteredConversationItems.first?.id == movedID }
        XCTAssertTrue(published, "The list's view model never moved the conversation to the top")

        let fresh = try await mountSidebar(over: mailbox)
        XCTAssertEqual(fresh.viewModel.filteredConversationItems.first?.id, movedID)
        let expected = try XCTUnwrap(drawing(of: fresh.table))
        XCTAssertNotEqual(before, expected, "The move changes nothing the sidebar draws, so this compares nothing")

        let followed = await waitUntil { self.drawing(of: sidebar.table) == self.drawing(of: fresh.table) }
        attach(drawing(of: sidebar.table), named: "sidebar-after-the-move")
        attach(drawing(of: fresh.table), named: "sidebar-fresh")
        XCTAssertTrue(followed, "After a conversation moved to the top, the sidebar does not draw what a fresh sidebar draws")
    }

    /// The list's selection is a set of row ids, and the mailbox's a set of object IDs. A click
    /// on a row has to open that row's conversation.
    ///
    /// Revert-check: returning `[]` from `MacSidebarRowID.conversationIDs(for:)` makes this
    /// fail.
    func testSidebar_selectingARowInTheTable_selectsThatRowsConversation() async throws {
        let mailbox = try makeMailbox(conversationCount: 12)
        let sidebar = try await mountSidebar(over: mailbox)
        let conversationID = sidebar.viewModel.filteredConversationItems[2].id

        sidebar.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let selected = await waitUntil { sidebar.selection.conversationIDs == [conversationID] }
        XCTAssertTrue(selected, "Selecting row 2 gave the mailbox \(sidebar.selection.conversationIDs)")
    }

    /// The other direction: a selection the mailbox sets (a just-sent conversation, the next
    /// row after an archive) has to reach the table.
    ///
    /// Revert-check: returning `[]` from `MacSidebarRowID.rowIDs(for:)` makes this fail.
    func testSidebar_aSelectionSetByTheMailbox_selectsItsRowInTheTable() async throws {
        let mailbox = try makeMailbox(conversationCount: 12)
        let sidebar = try await mountSidebar(over: mailbox)
        let conversationID = sidebar.viewModel.filteredConversationItems[4].id

        sidebar.selection.requests.send([conversationID])

        let selected = await waitUntil { sidebar.table.selectedRowIndexes == IndexSet(integer: 4) }
        XCTAssertTrue(selected, "The table's selection is \(Array(sidebar.table.selectedRowIndexes))")
    }

    // MARK: - Lists of this file's own

    private struct Row {
        let conversationID: NSManagedObjectID
        let title: String

        var rowID: MacSidebarRowID {
            MacSidebarRowID(conversationID: conversationID)
        }
    }

    private final class Rows: ObservableObject {
        @Published var rows: [Row]

        init(_ rows: [Row]) {
            self.rows = rows
        }
    }

    /// The `ForEach` is given the row and nothing around it: a row built with `if`/`else` hides
    /// the fault (`MacSidebarRowID`).
    private struct ObjectIDList: View {
        @ObservedObject var model: Rows

        var body: some View {
            List {
                ForEach(model.rows, id: \.conversationID) { row in
                    Text(row.title)
                }
            }
            .listStyle(.inset)
            .frame(width: 320, height: 600)
        }
    }

    private struct RowIDList: View {
        @ObservedObject var model: Rows

        var body: some View {
            List {
                ForEach(model.rows, id: \.rowID) { row in
                    Text(row.title)
                }
            }
            .listStyle(.inset)
            .frame(width: 320, height: 600)
        }
    }

    private func makeRows(count: Int) throws -> [Row] {
        let stack = TestCoreDataStack()
        stacks.append(stack)
        let viewContext = stack.makeMainQueueViewContext()
        let conversations = (0..<count).map { index in
            ConversationBuilder()
                .asList()
                .withListId("row\(index).example.com")
                .build(in: viewContext)
        }
        // Permanent ids, as the app's rows have. Temporary ones went wrong the same way.
        try viewContext.obtainPermanentIDs(for: conversations)
        return conversations.enumerated().map { index, conversation in
            Row(conversationID: conversation.objectID, title: "Row \(index)")
        }
    }

    private static func moving(_ rows: [Row], from source: Int, to destination: Int) -> [Row] {
        var moved = rows
        moved.insert(moved.remove(at: source), at: destination)
        return moved
    }

    // MARK: - The sidebar, mounted

    private static let firstDate = Date(timeIntervalSince1970: 1_768_000_000)

    private struct Mailbox {
        let stack: TestCoreDataStack
        let viewContext: NSManagedObjectContext
    }

    /// The mailbox's selection, from outside the views. The selection itself is `@State` in
    /// the host, as it is in `MacMailboxView`: the list writes it while the table is updating,
    /// and a published property written then logs a SwiftUI fault of the test's own making.
    private final class Selection {
        /// What the host's state holds now.
        var conversationIDs: Set<NSManagedObjectID> = []
        /// A selection for the host to take, as the mailbox sets one.
        let requests = PassthroughSubject<Set<NSManagedObjectID>, Never>()
    }

    private struct MountedSidebar {
        let table: NSTableView
        let viewModel: ConversationListViewModel
        let selection: Selection
    }

    private struct NoAbandonedActions: AbandonedPendingActionsManaging {
        func fetchAbandonedActions() async -> [AbandonedActionInfo] { [] }
        func retryAllAbandonedActions() async {}
        func dismissAllAbandonedActions() async {}
    }

    private struct SidebarHost: View {
        @ObservedObject var viewModel: ConversationListViewModel
        let selection: Selection
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
            .onChange(of: selectedConversationIDs) { _, conversationIDs in
                selection.conversationIDs = conversationIDs
            }
            .onReceive(selection.requests) { conversationIDs in
                selectedConversationIDs = conversationIDs
            }
        }
    }

    /// Mailing-list conversations ten minutes apart, each with a message: the list's launch
    /// repair archives a conversation that has none.
    private func makeMailbox(conversationCount: Int) throws -> Mailbox {
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
        return Mailbox(stack: stack, viewContext: viewContext)
    }

    private func mountSidebar(over mailbox: Mailbox) async throws -> MountedSidebar {
        let viewModel = ConversationListViewModel(
            dependencies: .forTesting(stack: mailbox.stack, viewContext: mailbox.viewContext)
        )
        let selection = Selection()
        let host = try mountInTestWindow(
            SidebarHost(
                viewModel: viewModel,
                selection: selection,
                abandonedActions: AbandonedPendingActionsModel(manager: NoAbandonedActions()),
                viewContext: mailbox.viewContext
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
            // Laid out as well as loaded: a table with no visible rect has nothing to draw.
            return count > 0 && found?.numberOfRows == count && found.flatMap(self.drawing(of:)) != nil
        }
        XCTAssertTrue(loaded, "The sidebar's list never loaded its rows")
        return MountedSidebar(
            table: try XCTUnwrap(found, "SwiftUI built no NSTableView for the sidebar's list"),
            viewModel: viewModel,
            selection: selection
        )
    }

    // MARK: - Helpers

    private func tableOfMounted<Content: View>(_ list: Content, rowCount: Int) async throws -> NSTableView {
        let host = try mountInTestWindow(list)
        var found: NSTableView?
        let loaded = await waitUntil {
            host.view.layoutSubtreeIfNeeded()
            found = Self.tableView(in: host.view)
            // Laid out as well as loaded: a table with no visible rect has nothing to draw.
            return found?.numberOfRows == rowCount && found.flatMap(self.drawing(of:)) != nil
        }
        XCTAssertTrue(loaded, "The list never loaded its rows")
        return try XCTUnwrap(found, "SwiftUI built no NSTableView for the list")
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

    /// The table's visible rows, as it draws them.
    private func drawing(of table: NSTableView) -> Data? {
        let rect = table.visibleRect
        guard !rect.isEmpty, let bitmap = table.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        table.cacheDisplay(in: rect, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func attach(_ drawing: Data?, named name: String) {
        guard let drawing else { return }
        let attachment = XCTAttachment(data: drawing, uniformTypeIdentifier: "public.png")
        attachment.name = name
        add(attachment)
    }

    /// Returns whether `condition` came true before the deadline. It does not fail the test:
    /// one test here asserts that a condition is never reached.
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
