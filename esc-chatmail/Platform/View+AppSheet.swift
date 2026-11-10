import SwiftUI

extension View {
    /// Presents a sheet. Every sheet the Mac can present goes through here or the `item:` form
    /// below, and nothing else the Mac compiles calls SwiftUI's `sheet` (`AppSheetSourceTests`
    /// scans the sources for one outside an `#if os(iOS)` branch).
    ///
    /// `chrome` is required because a Mac sheet that is given no size comes up as an empty strip
    /// 80 points tall that still blocks the window and Quit (`MacSheetSize`). On iOS this is
    /// exactly `sheet(isPresented:onDismiss:content:)`: `macSheetChrome(_:)` returns the content
    /// unchanged there.
    func appSheet<Content: View>(
        isPresented: Binding<Bool>,
        mac chrome: MacSheetChrome,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().macSheetChrome(chrome)
        }
    }

    /// Presents a sheet for an item; `chrome` gives each item its Mac size and close control.
    /// See `appSheet(isPresented:mac:onDismiss:content:)`.
    func appSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        mac chrome: @escaping (Item) -> MacSheetChrome,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item).macSheetChrome(chrome(item))
        }
    }
}
