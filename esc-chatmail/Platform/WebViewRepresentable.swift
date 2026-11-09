import SwiftUI
import WebKit

#if canImport(UIKit)
/// A SwiftUI wrapper around a `WKWebView`, written once for both platforms. Conformers implement
/// `makeWebView`, `updateWebView` and, when they need teardown, `dismantleWebView`; this protocol
/// supplies `UIViewRepresentable`'s methods on iOS and `NSViewRepresentable`'s on the Mac.
@MainActor
protocol WebViewRepresentable: UIViewRepresentable where UIViewType == WKWebView {
    func makeWebView(context: Context) -> WKWebView
    func updateWebView(_ webView: WKWebView, context: Context)
    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator)
}

extension WebViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        updateWebView(uiView, context: context)
    }

    /// Replaces `UIViewRepresentable`'s empty default, so SwiftUI's teardown reaches
    /// `dismantleWebView`.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        dismantleWebView(uiView, coordinator: coordinator)
    }
}
#elseif canImport(AppKit)
/// A SwiftUI wrapper around a `WKWebView`, written once for both platforms. Conformers implement
/// `makeWebView`, `updateWebView` and, when they need teardown, `dismantleWebView`; this protocol
/// supplies `UIViewRepresentable`'s methods on iOS and `NSViewRepresentable`'s on the Mac.
@MainActor
protocol WebViewRepresentable: NSViewRepresentable where NSViewType == WKWebView {
    func makeWebView(context: Context) -> WKWebView
    func updateWebView(_ webView: WKWebView, context: Context)
    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator)
}

extension WebViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        updateWebView(nsView, context: context)
    }

    /// Replaces `NSViewRepresentable`'s empty default, so SwiftUI's teardown reaches
    /// `dismantleWebView`.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        dismantleWebView(nsView, coordinator: coordinator)
    }
}
#endif

extension WebViewRepresentable {
    /// No teardown beyond SwiftUI releasing the view.
    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator) {}
}
