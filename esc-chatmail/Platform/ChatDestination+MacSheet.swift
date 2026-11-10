import Foundation

extension ChatDestination {
    /// The size this destination's sheet takes on the Mac; nil for the Contacts sheets, which
    /// size themselves (`OpenInContactsSheet`).
    var macSheetSize: MacSheetSize? {
        switch self {
        case .emailReader:
            return .reader
        case .forwardCompose:
            return .compose
        case .participants:
            return .list
        case .addContact, .contactPicker:
            return nil
        }
    }

    /// Whether this destination's sheet needs the Mac's Done bar (`MacSheetDoneBar`): only the
    /// email reader, which has no control of its own to close it. The others bring their own
    /// Done, Cancel or Send.
    var needsMacSheetDoneBar: Bool {
        switch self {
        case .emailReader:
            return true
        case .forwardCompose, .participants, .addContact, .contactPicker:
            return false
        }
    }
}
