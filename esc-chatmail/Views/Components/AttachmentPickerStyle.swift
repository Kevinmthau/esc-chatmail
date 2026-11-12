import CoreGraphics

/// How `AttachmentPicker` offers its two pickers, Photos and Files.
enum AttachmentPickerStyle: Equatable {
    /// A photo button and a paperclip button side by side: the iPhone's reply bar.
    case inlineButtons
    /// One "+" button of the diameter given that opens a menu of the two: the Mac's composer
    /// (`MacAttachmentMenuButton`). Where there is no such button (iOS), the inline buttons.
    case plusMenu(diameter: CGFloat)
}
