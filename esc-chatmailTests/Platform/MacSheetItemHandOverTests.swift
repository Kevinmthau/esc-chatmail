import SwiftUI
import XCTest
@testable import esc_chatmail

/// `View.onSheetItemShown(_:perform:)` is how `appSheet(item:)` tells a presenter which item is
/// on screen: when its content appears, and when the Mac has given the sheet's window to
/// another item (`View.onMacSheetItemHandOver(to:perform:)`). `ChatView` kept that record with
/// an `onAppear` alone, went on taking Participants for the sheet on screen after New Contact
/// replaced it, and refused every dismissal of New Contact: neither of that sheet's buttons
/// closed it (build 562, 2026-11-15).
///
/// The stand-in is the content `appSheet(item:)` builds: a `switch` over the item with the
/// report on the view the `switch` makes, where `ChatView` had its `onAppear`. So the tests
/// also show the fault's premise, on both platforms: a replacement in place runs the views
/// inside the `switch` again and not an `onAppear` on its result, or the reports would count
/// one more.
///
/// HONEST SCOPE: no test presents a sheet, so these mount the content a sheet would hold, in a
/// window of the test host, and replace its item in place, which is what the Mac does to a
/// sheet whose item is replaced before SwiftUI's next update. That the Mac's sheet does so, with
/// no `onDismiss` and no second `onAppear`, and that the chat's sheet then closes, was measured
/// in a throwaway program that presented through `appSheet(item:)` itself (macOS 27.2.1);
/// nothing here proves it, and the fix has not been seen in the app.
@MainActor
final class MacSheetItemHandOverTests: XCTestCase {
    #if os(macOS)
    /// Revert-check: replacing `onChange(of: id) { action() }` with `self` in
    /// `View.onMacSheetItemHandOver(to:perform:)`, or deleting
    /// `.onMacSheetItemHandOver(to: id, perform: action)` from `View.onSheetItemShown`, makes
    /// this fail.
    func testOnSheetItemShown_itemReplacedInPlace_reportsTheNewItemOnce() throws {
        let model = SheetContentModel()
        _ = try mountInTestWindow(SheetContentStandIn(model: model))
        XCTAssertTrue(
            waitUntil { model.shown == [.participants] && model.reported == [.participants] },
            "shown: \(model.shown), reported: \(model.reported)"
        )

        model.item = .newContact

        // The hand-over's report comes before the incoming view's own `onAppear`, so both are
        // waited for, and then the run loop is given time to deliver a report too many.
        XCTAssertTrue(
            waitUntil { model.shown == [.participants, .newContact] && model.reported.count >= 2 },
            "shown: \(model.shown), reported: \(model.reported)"
        )
        settle()
        XCTAssertEqual(
            model.reported,
            [.participants, .newContact],
            "Once for the appearance and once for the hand-over: the onAppear must not run again"
        )
        XCTAssertEqual(model.shown, [.participants, .newContact])
    }
    #elseif os(iOS)
    /// iOS dismisses a sheet whose item changes and presents the next one, with `onDismiss` and
    /// `onAppear`, so the presenter needs nothing more; and where the outgoing sheet's content
    /// is given the new item before its `onDismiss`, a report would make `ChatView` take the
    /// incoming destination for the one dismissed and clear it. Only iOS 27.0 was measured, so
    /// on iOS the report stays the content's `onAppear` and no more.
    ///
    /// Revert-check: removing the `#if os(macOS)` branch from
    /// `View.onMacSheetItemHandOver(to:perform:)`, so it calls `onChange` everywhere, makes this
    /// fail; so does deleting `onAppear(perform: action)` from `View.onSheetItemShown`.
    func testOnSheetItemShown_itemReplacedInPlaceOnIOS_reportsOnlyTheAppearance() throws {
        let model = SheetContentModel()
        _ = try mountInTestWindow(SheetContentStandIn(model: model))
        XCTAssertTrue(
            waitUntil { model.shown == [.participants] && model.reported == [.participants] },
            "shown: \(model.shown), reported: \(model.reported)"
        )

        model.item = .newContact

        XCTAssertTrue(waitUntil { model.shown == [.participants, .newContact] }, "shown: \(model.shown)")
        // An `onChange` action runs in the update that draws the new item or the turn after
        // it; this is long past both.
        settle()
        XCTAssertEqual(model.reported, [.participants])
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

    /// Gives SwiftUI time to deliver anything it still owes, for an assertion that nothing
    /// more arrives, which no condition can be waited on for.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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
    /// The items reported as on screen, in order.
    var reported: [SheetItemStandIn] = []
}

/// What `appSheet(item:)` gives its sheet: the presenter's content, a `switch` over the item,
/// with the report on the view the `switch` makes.
private struct SheetContentStandIn: View {
    @ObservedObject var model: SheetContentModel

    var body: some View {
        let item = model.item
        content(item)
            .onSheetItemShown(item.rawValue) {
                model.reported.append(item)
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
