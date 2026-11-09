#if os(iOS)
import SwiftUI
import CoreData

/// The iOS document picker for draft attachments. Importing is `DocumentAttachmentImporter`'s;
/// the Mac picks with `.fileImporter` instead (`View.documentAttachmentPicker`).
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var attachments: [Attachment]
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.managedObjectContext) private var viewContext
    let onProcessingChanged: @MainActor (Bool) -> Void
    let onOperationChanged: @MainActor (Task<Void, Never>?) -> Void
    let onImportFailures: @MainActor ([String]) -> Void

    init(
        attachments: Binding<[Attachment]>,
        onProcessingChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onOperationChanged: @escaping @MainActor (Task<Void, Never>?) -> Void = { _ in },
        onImportFailures: @escaping @MainActor ([String]) -> Void = { _ in }
    ) {
        self._attachments = attachments
        self.onProcessingChanged = onProcessingChanged
        self.onOperationChanged = onOperationChanged
        self.onImportFailures = onImportFailures
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: DocumentAttachmentImporter.allowedContentTypes
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DocumentAttachmentImporter(
                attachments: parent.$attachments,
                viewContext: parent.viewContext,
                onProcessingChanged: parent.onProcessingChanged,
                onOperationChanged: parent.onOperationChanged,
                onImportFailures: parent.onImportFailures
            )
            .importDocuments(at: urls)
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
#endif
