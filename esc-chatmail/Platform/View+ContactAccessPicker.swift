import SwiftUI
#if os(iOS)
import ContactsUI
#endif

extension View {
    /// iOS 18's Contacts access picker (`contactAccessPicker`), which lets a user with limited
    /// Contacts access share one more contact. Unchanged on iOS 17, which has no picker; unchanged
    /// on the Mac too, which has no limited access and so never asks for it
    /// (`CNAuthorizationStatus.isLimitedAccess`).
    @ViewBuilder
    func contactAccessPickerIfAvailable(
        isPresented: Binding<Bool>,
        completion: @escaping ([String]) -> Void
    ) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            contactAccessPicker(isPresented: isPresented, completionHandler: completion)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
