import SwiftUI

extension ToolbarContent {
    /// Takes a toolbar item off the glass the Mac's window toolbar puts behind its items.
    ///
    /// Every item in the Mac's toolbar sits on a glass platter. That suits a button. Behind the
    /// chat header's avatar it showed as a crescent of glass under the circle, and Messages'
    /// avatar has none (`ChatHeaderPolicy.hidesPrincipalItemGlass`). Hiding it also moves the
    /// item: the toolbar centers a principal item 2.5 points right of the chat column's center
    /// on its platter and 0.5 points right of it without one, so the name capsule's offset is
    /// the number for this choice (`ChatHeaderMetrics.principalItemCenterOffset`). Measured
    /// with the header's own views under a real window toolbar, in the test host on
    /// macOS 27.2; not seen in the app.
    ///
    /// `false` leaves the item as the toolbar draws it. Changes nothing on iOS, whose
    /// navigation bar is not asked about its items' backgrounds here.
    func macSharedBackgroundHidden(_ isHidden: Bool) -> some ToolbarContent {
        #if os(macOS)
        sharedBackgroundVisibility(isHidden ? .hidden : .automatic)
        #else
        self
        #endif
    }
}
