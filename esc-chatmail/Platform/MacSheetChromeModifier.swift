#if os(macOS)
import SwiftUI

/// A sheet's Mac chrome (`View.macSheetChrome(_:)`): the Done bar where the sheet has no control
/// of its own to close it, then the size.
///
/// The frame allows the sheet one width: its minimum, ideal and maximum are all
/// `MacSheetSize.width`. The Mac's own sheet sizing offers the content 470 points of width and
/// leaves the height to it, and a frame answers an offer with the nearest width it allows. Given
/// a minimum and an ideal only, it answered 470, or the minimum where that is more, never the
/// ideal (the reader opened 560 by 720, not 760 wide). Both bounds are needed: without the
/// maximum a sheet narrower than 470 points opens 470 wide (Participants), and without the
/// minimum a wider one does (the reader). The height keeps a minimum and an ideal, because the
/// system's height was right already: the ideal, capped by the window the sheet hangs from.
///
/// Do not take the width from the sheet's sizing instead (`presentationSizing`, fitted to the
/// content). It gave the ideal width, with three faults (all measured on macOS 27.2,
/// 2026-11-10), and `AppSheetSourceTests` fails on a call to it:
/// - The content was laid out twice as the sheet opened, at its minimum width and then its
///   ideal. A reader whose email is ready makes its WebView in the first layout, and a
///   pre-rendered WebView is adopted only at the width it was rendered at
///   (`FullEmailWebViewPreRenderKey`), so no open could adopt one.
/// - The sheet's window could be resized, and the reader asks for a new pre-render at every
///   whole point of width it is laid out at (`FullEmailOpenSession.prepareForMeasuredReaderWidth`).
/// - `appSheet(item:)` reuses the sheet's window when one item follows another (Participants,
///   then the Contacts sheet), and a fitted window kept what it had: the Contacts sheet could
///   be resized, and a sheet with a size opened at the size of the one before it.
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
                minWidth: chrome.size?.width,
                idealWidth: chrome.size?.width,
                maxWidth: chrome.size?.width,
                minHeight: chrome.size?.minHeight,
                idealHeight: chrome.size?.idealHeight
            )
    }
}
#endif
