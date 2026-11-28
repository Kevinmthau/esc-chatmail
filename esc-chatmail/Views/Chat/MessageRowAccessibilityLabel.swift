import SwiftUI

/// Says `prefix` (`MessageRowAccessibilityPolicy.labelPrefix`) before a combined bubble
/// column's own label, which is its children's text (architecture review 2026-11,
/// gap-accessibility-architecture#1).
///
/// From iOS 18, and on the Mac (macOS 26 and later), through `accessibilityLabel(content:)`,
/// which keeps the children's label after the prefix. iOS 17 has no way to add to a combined
/// label short of replacing it, which would rebuild the content's text, so there the prefix is
/// custom content, which VoiceOver offers under More Content. The availability branch is fixed
/// for the process, so it never changes a mounted row's structure.
struct MessageRowAccessibilityLabel: ViewModifier {
    let prefix: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.accessibilityLabel { label in
                Text(prefix)
                label
            }
        } else {
            content.accessibilityCustomContent(Text("Message"), Text(prefix))
        }
    }
}
