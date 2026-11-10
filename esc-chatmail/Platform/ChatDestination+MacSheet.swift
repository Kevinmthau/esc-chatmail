import Foundation

extension ChatDestination {
    /// The size and close control this destination's sheet takes on the Mac.
    ///
    /// - The email reader has no control of its own to close it, so it gets the Done bar.
    /// - Forward and Participants bring their own Cancel, Send or Done.
    /// - The Contacts sheets size themselves and bring their own buttons
    ///   (`OpenInContactsSheet`). The Mac presents `.addContact`; it never presents
    ///   `.contactPicker` (`ContactsSheet.supportsContactPicker`).
    var macSheetChrome: MacSheetChrome {
        switch self {
        case .emailReader:
            return .sizedWithDoneBar(.reader)
        case .forwardCompose:
            return .sized(.compose)
        case .participants:
            return .sized(.list)
        case .addContact, .contactPicker:
            return .sizesItself
        }
    }
}
