import Foundation

enum EmailPreviewSnapshotFeatureFlag {
    private static let defaults = UserDefaults.standard

    static var isEnabled: Bool {
        defaults.bool(forKey: "EmailPreviewSnapshots_Enabled")
    }

    static var fallbackToLiveWebView: Bool {
        if let value = defaults.object(forKey: "EmailPreviewSnapshots_FallbackToLiveWebView") as? Bool {
            return value
        }
        return true
    }
}
