#if os(macOS)
import SwiftUI

/// Gives a view presented as a sheet its title on the Mac (`View.macSheetNavigationTitle(_:)`).
///
/// A Mac sheet has no toolbar and draws no `.principal` item, which is where such a view shows
/// its title on iOS. It does draw a navigation title, in a strip along its top edge, and draws
/// it once when the view has a principal item as well.
///
/// A view with no title must get no navigation title at all: an empty one still draws the strip,
/// empty, above the content. That is why this branches instead of always applying a title, and
/// the branch never changes for a given view (`ComposeView`'s presentation is fixed when it is
/// created), so the content keeps one identity. All measured on macOS 27.2, 2026-11-10.
struct MacSheetNavigationTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}
#endif
