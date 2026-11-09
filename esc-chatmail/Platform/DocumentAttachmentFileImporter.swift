#if os(macOS)
import SwiftUI
import CoreData

/// The Mac's document picker for draft attachments (`View.documentAttachmentPicker`): SwiftUI's
/// `.fileImporter`, importing through the same `DocumentAttachmentImporter` as iOS's picker.
/// The sandbox grants the picked files through `ENABLE_USER_SELECTED_FILES`, and the importer
/// opens each one's security scope as it reads it.
struct DocumentAttachmentFileImporter: ViewModifier {
    @Binding var isPresented: Bool
    let attachments: Binding<[Attachment]>
    let onProcessingChanged: @MainActor (Bool) -> Void
    let onOperationChanged: @MainActor (Task<Void, Never>?) -> Void
    let onImportFailures: @MainActor ([String]) -> Void
    @Environment(\.managedObjectContext) private var viewContext

    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: $isPresented,
            allowedContentTypes: DocumentAttachmentImporter.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                DocumentAttachmentImporter(
                    attachments: attachments,
                    viewContext: viewContext,
                    onProcessingChanged: onProcessingChanged,
                    onOperationChanged: onOperationChanged,
                    onImportFailures: onImportFailures
                )
                .importDocuments(at: urls)
            case .failure(let error):
                Log.error("The document picker failed", category: .ui, error: error)
            }
        }
    }
}
#endif
