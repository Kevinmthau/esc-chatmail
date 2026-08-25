//
//  AppLoadingView.swift
//  esc-chatmail
//

import SwiftUI

/// Loading view shown during app initialization.
/// Displayed while Core Data loads and fresh install cleanup completes.
struct AppLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("MushMail")
                .font(.title)
                .fontWeight(.bold)

            ProgressView()
        }
    }
}

#Preview {
    AppLoadingView()
}
