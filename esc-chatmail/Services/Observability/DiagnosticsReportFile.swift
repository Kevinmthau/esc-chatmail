import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What the Share Diagnostics item hands the share sheet: the report, made only when the
/// user picks where to send it.
struct DiagnosticsReportFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { _ in
            SentTransferredFile(try DiagnosticsReport.writeFile(store: .shared))
        }
    }
}
