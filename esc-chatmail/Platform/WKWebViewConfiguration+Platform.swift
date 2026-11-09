import WebKit

/// The full reader's `WKWebViewConfiguration` settings that exist only on iOS.
extension WKWebViewConfiguration {
    /// iOS: plays media full screen rather than inline, and turns phone numbers, links and
    /// addresses into data-detector links.
    ///
    /// Nothing on the Mac, which has neither setting: media always plays inline there (the
    /// shared `mediaTypesRequiringUserActionForPlayback = .all` still waits for a click), and
    /// with no data detectors the `x-apple-data-detectors` branch of
    /// `FullInteractiveEmailWebView.navigationDecision` never runs.
    func applyFullReaderMediaAndDataDetectorSettings() {
        #if canImport(UIKit)
        allowsInlineMediaPlayback = false
        dataDetectorTypes = [.phoneNumber, .link, .address]
        #endif
    }
}
