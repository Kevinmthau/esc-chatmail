import SwiftUI

/// Full interactive WebView for displaying email HTML content
/// Wraps BaseEmailWebView with fullInteractive mode
struct HTMLWebView: View {
    let htmlContent: String
    let isDarkMode: Bool

    var body: some View {
        BaseEmailWebView(
            htmlContent: htmlContent,
            mode: .fullInteractive,
            isDarkMode: isDarkMode
        )
    }
}
