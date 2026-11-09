import SwiftUI

extension View {
    /// An email-address text field's input traits: no autocapitalization and the email keyboard
    /// on iOS. The Mac has neither (a hardware keyboard, no automatic capitalization), so there
    /// it changes nothing.
    func emailAddressTextInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
        #else
        self
        #endif
    }
}
