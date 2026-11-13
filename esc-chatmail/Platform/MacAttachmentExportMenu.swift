#if os(macOS)
import SwiftUI

/// The menu a right-click on an attachment in a Mac chat opens
/// (`View.macAttachmentExportMenu`): Quick Look, Save Attachment…, and Save All Attachments…
/// where the message shows more than one (`AttachmentExportPolicy.menu`), then the entries
/// of the message the attachment is in.
///
/// The message's row has a menu of its own (Reply, Forward, View original email). A right-click
/// on a view with its own context menu opens that one and not the one around it: measured in
/// the sandboxed test host on macOS 27.2 (2026-11-13), by asking the hosting view for the menu
/// of a right-click, where a `contextMenu` inside another with a preview answered with the
/// inner one's entries. So on an attachment this menu replaces the message's, which stays on
/// the rest of the row, and the message's entries are in this menu because the row hands
/// them down (`MacEnclosingMessageMenu`). Without them a message that is only a photo had
/// no Reply or Forward in any menu. An attachment drawn outside a message's row is handed
/// none and has its own entries only.
///
/// The attachments are managed objects of the view context, read when an entry is chosen and
/// handed on as values (`AttachmentExportItem`): the row can be gone, and its message replaced
/// by its echo, before a save panel closes.
struct MacAttachmentExportMenu: ViewModifier {
    /// The attachment that was right-clicked.
    let attachment: Attachment
    /// Every attachment the message shows, the clicked one among them.
    let shownAttachments: [Attachment]
    let onQuickLook: () -> Void
    var exporter: MacAttachmentExporter = .shared
    /// The attachment's file and name, nil where it has no file. A parameter so the tests can
    /// keep their files in a temporary directory.
    var resolveItem: (Attachment) -> AttachmentExportItem? = { AttachmentExportItem(attachment: $0) }
    /// In a property wrapper, which neither of the two compilers this builds with makes a
    /// parameter of the memberwise initializer the tests use.
    @Environment(\.macEnclosingMessageMenu) private var messageMenu

    func body(content: Content) -> some View {
        content.contextMenu {
            let entries = AttachmentExportPolicy.menu(
                isReady: attachment.isReady,
                readyCount: shownAttachments.filter(\.isReady).count,
                shownCount: shownAttachments.count
            )
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Button(AttachmentExportPolicy.title(for: entry.item)) {
                    perform(entry.item)
                }
                .disabled(!entry.isEnabled)
            }
            if let messageMenu {
                Divider()
                messageMenu.entries()
            }
        }
    }

    private func perform(_ item: AttachmentExportPolicy.MenuItem) {
        switch item {
        case .quickLook:
            onQuickLook()
        case .save:
            let exportItem = resolveItem(attachment)
            let displayFilename = AttachmentExportItem.displayFilename(of: attachment)
            Task {
                await exporter.save(exportItem, displayFilename: displayFilename)
            }
        case .saveAll:
            let resolved = AttachmentExportItem.resolve(shownAttachments, resolveItem: resolveItem)
            Task {
                await exporter.saveAll(resolved.items, missingFilenames: resolved.missingFilenames)
            }
        }
    }
}
#endif
