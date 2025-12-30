import Foundation

// MARK: - Message Window
struct MessageWindow {
    let startIndex: Int
    let endIndex: Int
    var messages: [Message]
    var isLoading: Bool

    var range: Range<Int> {
        startIndex..<endIndex
    }

    func contains(index: Int) -> Bool {
        range.contains(index)
    }
}
