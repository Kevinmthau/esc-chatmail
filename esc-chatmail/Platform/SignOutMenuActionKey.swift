#if os(macOS)
import SwiftUI

/// The focused-value key `SignOutMenuAction` is published under.
private struct SignOutMenuActionKey: FocusedValueKey {
    typealias Value = SignOutMenuAction
}

extension FocusedValues {
    /// Nil while no window is focused, which leaves the menu command disabled.
    var signOutMenuAction: SignOutMenuAction? {
        get { self[SignOutMenuActionKey.self] }
        set { self[SignOutMenuActionKey.self] = newValue }
    }
}
#endif
