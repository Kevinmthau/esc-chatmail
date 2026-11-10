#if os(macOS)
import SwiftUI

/// A sheet's Mac chrome (`View.macSheetChrome(_:)`): the Done bar where the sheet has no control
/// of its own to close it, then the size.
///
/// It wraps every sheet the same way, whatever `chrome` says, so a sheet's content keeps one
/// structural identity. A sheet without the bar gets an empty bottom inset and one that sizes
/// itself a frame with no bounds; neither changes its layout (compared pixel for pixel on macOS
/// 27.2, 2026-11-10).
struct MacSheetChromeModifier: ViewModifier {
    let chrome: MacSheetChrome

    func body(content: Content) -> some View {
        content
            .modifier(MacSheetDoneBar(isShown: chrome.showsDoneBar))
            .frame(
                minWidth: chrome.size?.minWidth,
                idealWidth: chrome.size?.idealWidth,
                minHeight: chrome.size?.minHeight,
                idealHeight: chrome.size?.idealHeight
            )
    }
}
#endif
