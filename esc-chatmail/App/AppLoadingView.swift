//
//  AppLoadingView.swift
//  esc-chatmail
//

import SwiftUI

/// Loading view shown during app initialization.
/// Displayed while Core Data loads and fresh install cleanup completes, and
/// in place of the spinner when the store could not be opened.
struct AppLoadingView: View {
    @ObservedObject private var model: AppLoadingModel
    @State private var isConfirmingMailboxReset = false

    @MainActor
    init(model: AppLoadingModel? = nil) {
        _model = ObservedObject(wrappedValue: model ?? .shared)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("MushMail")
                .font(.title)
                .fontWeight(.bold)

            if let failure = model.storeLoadFailure {
                VStack(spacing: 12) {
                    Text(failure.title)
                        .font(.headline)
                    Text(failure.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        model.retry()
                    }
                    .buttonStyle(.borderedProminent)
                    if failure.offersMailboxReset {
                        Button("Reset Mailbox…", role: .destructive) {
                            isConfirmingMailboxReset = true
                        }
                    }
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView()
            }
        }
        .alert(
            AppLoadingPolicy.mailboxResetConfirmation.title,
            isPresented: $isConfirmingMailboxReset
        ) {
            Button(AppLoadingPolicy.mailboxResetConfirmation.confirmButtonTitle, role: .destructive) {
                model.resetMailbox()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AppLoadingPolicy.mailboxResetConfirmation.message)
        }
    }
}

#Preview {
    AppLoadingView()
}
