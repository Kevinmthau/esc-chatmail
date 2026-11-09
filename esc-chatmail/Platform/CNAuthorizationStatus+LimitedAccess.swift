import Contacts

extension CNAuthorizationStatus {
    /// Whether this is iOS 18's limited Contacts access (`.limited`): the user shared only some
    /// contacts. Callers that read or edit contacts treat it like `.authorized`.
    ///
    /// Always false on the Mac, where `.limited` does not exist (the Contacts grant there is all
    /// or nothing), and before iOS 18, where it did not exist yet.
    var isLimitedAccess: Bool {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            return self == .limited
        }
        return false
        #else
        return false
        #endif
    }
}
