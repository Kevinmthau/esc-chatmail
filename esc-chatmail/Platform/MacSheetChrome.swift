/// What a sheet needs on the Mac besides its content (`View.appSheet`): a size and, for a sheet
/// with no control of its own to close it, the Done bar.
///
/// Every sheet states one, because a Mac sheet that states nothing is as large as its content
/// asks to be, and the content of the app's sheets asks for nothing (`MacSheetSize`). There are
/// three forms and no other: a sheet that sizes itself always brings its own buttons.
struct MacSheetChrome: Equatable {
    /// Nil only for `sizesItself`.
    let size: MacSheetSize?
    /// Whether the sheet gets the Mac's Done bar (`MacSheetDoneBar`).
    let showsDoneBar: Bool

    private init(size: MacSheetSize?, showsDoneBar: Bool) {
        self.size = size
        self.showsDoneBar = showsDoneBar
    }

    /// A sheet that closes itself with its own Done, Cancel or Send.
    static func sized(_ size: MacSheetSize) -> MacSheetChrome {
        MacSheetChrome(size: size, showsDoneBar: false)
    }

    /// A sheet with no control of its own to close it. On iOS it is swiped down; a Mac sheet
    /// has no such gesture, so it gets a Done button along its bottom edge.
    static func sizedWithDoneBar(_ size: MacSheetSize) -> MacSheetChrome {
        MacSheetChrome(size: size, showsDoneBar: true)
    }

    /// A sheet that lays itself out and brings its own buttons (`OpenInContactsSheet`), which a
    /// size forced on it would only stretch.
    static let sizesItself = MacSheetChrome(size: nil, showsDoneBar: false)
}
