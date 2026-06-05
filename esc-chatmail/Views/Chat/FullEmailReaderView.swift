import SwiftUI

struct FullEmailReaderView: View {
    @ObservedObject var session: FullEmailOpenSession

    var body: some View {
        HTMLMessageView(
            message: session.message,
            initialOpenPayload: session.initialOpenPayload,
            initialPlaceholder: session.immediatePlaceholder
        )
    }
}
