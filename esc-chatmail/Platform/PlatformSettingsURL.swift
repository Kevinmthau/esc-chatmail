import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Where an "Open Settings" button sends the user to grant Contacts access.
enum PlatformSettingsURL {
    /// iOS: this app's page in the Settings app (`UIApplication.openSettingsURLString`), which
    /// holds its Contacts switch. The Mac: System Settings › Privacy & Security › Contacts, since
    /// a Mac app has no Settings-app page of its own.
    static var contactsAccess: URL? {
        #if canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        #endif
    }
}
