#if os(macOS)
import SwiftUI

/// The menu entries of the message a view is drawn in (`View.macEnclosingMessageMenu`), for a
/// view inside the row that has a context menu of its own.
///
/// A right-click on a view with its own context menu opens that one and not the row's
/// (`MacAttachmentExportMenu`), so on an attachment the message's Reply and Forward were out
/// of reach: a message that is only a photo had no Reply in any menu. The row hands its
/// entries down here and the attachment's menu ends with them.
///
/// The entries are built when a menu asks for them, from the one definition the row's own
/// menu uses (`ChatMessagesView.messageContextMenu`), so the two cannot differ.
struct MacEnclosingMessageMenu {
    let entries: () -> AnyView
}

private struct MacEnclosingMessageMenuKey: EnvironmentKey {
    static let defaultValue: MacEnclosingMessageMenu? = nil
}

extension EnvironmentValues {
    /// Nil outside a message's row: an attachment drawn anywhere else has its own entries only.
    var macEnclosingMessageMenu: MacEnclosingMessageMenu? {
        get { self[MacEnclosingMessageMenuKey.self] }
        set { self[MacEnclosingMessageMenuKey.self] = newValue }
    }
}
#endif
