import SwiftUI

struct EmailReaderView: View {
    @StateObject private var viewModel: EmailReaderViewModel
    private let onReply: (() -> Void)?
    private let onForward: (() -> Void)?

    init(
        route: EmailReaderRoute,
        chatDependencies: ChatDependencies,
        onReply: (() -> Void)? = nil,
        onForward: (() -> Void)? = nil
    ) {
        self._viewModel = StateObject(
            wrappedValue: EmailReaderViewModel(
                route: route,
                chatDependencies: chatDependencies
            )
        )
        self.onReply = onReply
        self.onForward = onForward
    }

    var body: some View {
        if let session = viewModel.session {
            FullEmailReaderView(
                session: session,
                mode: viewModel.mode,
                availableModes: viewModel.availableModes,
                onModeSelected: { mode in
                    viewModel.selectMode(mode)
                },
                onReply: onReply,
                onForward: onForward
            )
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
