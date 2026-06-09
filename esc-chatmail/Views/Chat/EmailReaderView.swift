import SwiftUI

struct EmailReaderView: View {
    @StateObject private var viewModel: EmailReaderViewModel

    init(
        route: EmailReaderRoute,
        chatDependencies: ChatDependencies
    ) {
        self._viewModel = StateObject(
            wrappedValue: EmailReaderViewModel(
                route: route,
                chatDependencies: chatDependencies
            )
        )
    }

    var body: some View {
        if let session = viewModel.session {
            FullEmailReaderView(session: session)
        } else {
            NavigationStack {
                VStack(spacing: 14) {
                    Image(systemName: "envelope.badge")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text(viewModel.errorMessage ?? "Original email unavailable")
                        .font(.headline)

                    Button {
                        viewModel.retryResolveRoute()
                    } label: {
                        SwiftUI.Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .navigationTitle("Email")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
