import Foundation
import SwiftSoup

// MARK: - Comment-delimited regions
//
// Some providers (notably Outlook) wrap quoted history in HTML comments
// (`<!-- originalmessage --> … <!-- /originalmessage -->`). SwiftSoup
// represents these as `Comment` nodes that CSS selectors can't reach, so the
// region is walked and removed directly.
extension EmailDOMQuoteRemover {

    /// Removes everything between `<!-- openHint -->` and `<!-- closeHint -->`
    /// inclusive. SwiftSoup represents these as `Comment` nodes; selectors
    /// don't reach them, so we walk the comment list directly.
    /// Returns true when a delimited region was found and removed.
    @discardableResult
    static func removeCommentDelimitedRegions(in document: Document, openHint: String, closeHint: String) -> Bool {
        guard let body = document.body() else { return false }
        var openComment: Comment?
        var closeComment: Comment?
        let openMatch = openHint.lowercased()
        let closeMatch = closeHint.lowercased()
        walkAllComments(in: body) { comment in
            let data = comment.getData().lowercased()
            if openComment == nil, data.contains(openMatch) {
                openComment = comment
            } else if openComment != nil, closeComment == nil, data.contains(closeMatch) {
                closeComment = comment
            }
        }
        guard let open = openComment, let close = closeComment else { return false }
        // Best-effort: if open and close share a parent, remove nodes between.
        // Otherwise just remove the two comments and let other passes handle the body.
        let openParent = open.parent() as? Element
        let closeParent = close.parent() as? Element
        if let parent = openParent, parent === closeParent {
            let children = parent.getChildNodes()
            var inside = false
            for child in children {
                if !inside {
                    if child === open {
                        inside = true
                    }
                    continue
                }
                if child === close {
                    try? child.remove()
                    inside = false
                    continue
                }
                try? child.remove()
            }
            try? open.remove()
            return true
        }
        try? open.remove()
        try? close.remove()
        return true
    }

    private static func walkAllComments(in node: Node, visit: (Comment) -> Void) {
        if let comment = node as? Comment {
            visit(comment)
        }
        for child in node.getChildNodes() {
            walkAllComments(in: child, visit: visit)
        }
    }
}
