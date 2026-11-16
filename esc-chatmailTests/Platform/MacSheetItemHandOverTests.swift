import SwiftUI
import XCTest
@testable import esc_chatmail

/// `View.onMacSheetItemHandOver(to:perform:)` tells a sheet's presenter that the Mac has given
/// the sheet's window to another item. Without it `ChatView` went on taking Participants for
/// the sheet on screen after New Contact replaced it, and refused every dismissal of New
/// Contact: neither of that sheet's buttons closed it (build 562, 2026-11-15).
///
/// HONEST SCOPE: no test presents a sheet, so these mount the content a sheet would hold, in a
/// window of the test host, and replace its item in place, which is what the Mac does to a
/// sheet whose item is replaced before SwiftUI's next update. That the Mac's sheet does so, with
/// no `onDismiss` and no second `onAppear`, and that the chat's sheet then closes, was measured
/// in a throwaway program built on the chat's bookkeeping and this helper's own file (macOS
/// 27.2.1); nothing here proves it, and the fix has not been seen in the app.
@MainActor
final class MacSheetItemHandOverTests: XCTestCase {
    #if os(macOS)
    /// Revert-check: replacing `onChange(of: id) { action() }` with `self` in
    /// `View.onMacSheetItemHandOver(to:perform:)` makes this fail.
    func testOnMacSheetItemHandOver_itemReplacedInPlace_runsTheActionForTheNewItem() throws {
        let model = SheetContentModel()
        _ = try mountInTestWindow(SheetContentStandIn(model: model))
        XCTAssertTrue(waitUntil { model.shown == [.participants] }, "shown: \(model.shown)")
        XCTAssertEqual(model.handedOver, [], "A sheet that opens is no hand-over: its onAppear reports it")

        model.item = .newContact

        XCTAssertTrue(waitUntil { model.handedOver == [.newContact] }, "handed over: \(model.handedOver)")
        XCTAssertEqual(model.shown, [.participants, .newContact])
    }
    #elseif os(iOS)
    /// iOS dismisses a sheet whose item changes and presents the next one, with `onDismiss` and
    /// `onAppear`, so the presenter needs nothing more; and where the outgoing sheet's content
    /// is given the new item before its `onDismiss`, the action would make `ChatView` clear the
    /// incoming destination. Only iOS 27.0 was measured, so iOS is left as it was.
    ///
    /// Revert-check: removing the `#if os(macOS)` branch from
    /// `View.onMacSheetItemHandOver(to:perform:)`, so it calls `onChange` everywhere, makes this
    /// fail.
    func testOnMacSheetItemHandOver_itemReplacedInPlaceOnIOS_neverRunsTheAction() throws {
        let model = SheetContentModel()
        _ = try mountInTestWindow(SheetContentStandIn(model: model))
        XCTAssertTrue(waitUntil { model.shown == [.participants] }, "shown: \(model.shown)")

        model.item = .newContact

        XCTAssertTrue(waitUntil { model.shown == [.participants, .newContact] }, "shown: \(model.shown)")
        // An `onChange` action runs in the update that draws the new item or the turn after
        // it; this is long past both.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(model.handedOver, [])
    }
    #endif

    /// Runs the run loop until `condition` holds or `timeout` has passed, and returns whether
    /// it held.
    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

private enum SheetItemStandIn: String {
    case participants
    case newContact
}

@MainActor
private final class SheetContentModel: ObservableObject {
    @Published var item: SheetItemStandIn = .participants
    /// The items whose own views appeared, in order: how a test knows an update was drawn.
    var shown: [SheetItemStandIn] = []
    /// The items the hand-over action ran for, in order.
    var handedOver: [SheetItemStandIn] = []
}

/// What `ChatView` gives its sheet: a `switch` over the item, with the hand-over action on the
/// view the `switch` makes.
private struct SheetContentStandIn: View {
    @ObservedObject var model: SheetContentModel

    var body: some View {
        let item = model.item
        content(item)
            .onMacSheetItemHandOver(to: item.rawValue) {
                model.handedOver.append(item)
            }
    }

    @ViewBuilder
    private func content(_ item: SheetItemStandIn) -> some View {
        switch item {
        case .participants:
            Text("Participants").onAppear { model.shown.append(.participants) }
        case .newContact:
            Text("New Contact").onAppear { model.shown.append(.newContact) }
        }
    }
}
