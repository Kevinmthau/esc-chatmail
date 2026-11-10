import SwiftUI

extension View {
    /// Presents the document picker for draft attachments while `isPresented` is true, and
    /// imports what the user picks (`DocumentAttachmentImporter`).
    ///
    /// iOS keeps its `UIDocumentPickerViewController` in a sheet (`DocumentPicker`), unchanged
    /// from before the Mac port. The Mac, which has no UIKit picker, uses SwiftUI's
    /// `.fileImporter` (`DocumentAttachmentFileImporter`); both import the same way.
    func documentAttachmentPicker(
        isPresented: Binding<Bool>,
        attachments: Binding<[Attachment]>,
        onProcessingChanged: @escaping @MainActor (Bool) -> Void,
        onOperationChanged: @escaping @MainActor (Task<Void, Never>?) -> Void,
        onImportFailures: @escaping @MainActor ([String]) -> Void
    ) -> some View {
        #if os(iOS)
        // SwiftUI's own `sheet`, not `appSheet`: this branch is iOS-only, and the Mac's
        // counterpart below is a system file panel, which needs no Mac sheet chrome.
        sheet(isPresented: isPresented) {
            DocumentPicker(
                attachments: attachments,
                onProcessingChanged: onProcessingChanged,
                onOperationChanged: onOperationChanged,
                onImportFailures: onImportFailures
            )
        }
        #else
        modifier(DocumentAttachmentFileImporter(
            isPresented: isPresented,
            attachments: attachments,
            onProcessingChanged: onProcessingChanged,
            onOperationChanged: onOperationChanged,
            onImportFailures: onImportFailures
        ))
        #endif
    }
}
