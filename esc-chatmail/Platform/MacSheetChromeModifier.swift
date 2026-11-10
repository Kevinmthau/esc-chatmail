#if os(macOS)
import SwiftUI

/// A sheet's Mac chrome (`View.macSheetChrome(_:)`): the Done bar where the sheet has no control
/// of its own to close it, then the size.
///
/// The frame alone does not give a sheet its ideal width. The Mac's own sheet sizing offers the
/// content 470 points of width and leaves the height to it, so a sheet with only the frame
/// opened at its ideal height and 470 points wide, or at its minimum width where that is more
/// (the reader 560 by 720, not 760 wide). Fitting the sizing's width to the content makes it
/// leave the width to the content too, and the frame then answers with its ideal one. A fitted
/// sheet's window is also resizable, with the frame's minimum as its minimum size.
///
/// Only the width is fitted, because the system's height was right already: the ideal height,
/// capped by the window the sheet hangs from. Fitting the height as well measured the same.
/// `.fitted` is a different sizing, not a shorter spelling: it drops that cap (the reader
/// opened 720 points tall on a window 300 points tall).
///
/// It wraps every sheet the same way, whatever `chrome` says, so a sheet's content keeps one
/// structural identity. A sheet without the bar gets an empty bottom inset, and one that sizes
/// itself a frame with no bounds and a sizing fitted on neither axis; none of the three changes
/// its layout (compared pixel for pixel on macOS 27.2, 2026-11-10).
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
            .presentationSizing(.automatic.fitted(horizontal: chrome.fitsIdealWidth, vertical: false))
    }
}
#endif
