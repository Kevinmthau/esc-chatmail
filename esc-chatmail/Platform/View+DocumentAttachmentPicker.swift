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
