import WebKit

/// The navigation policy of the two non-interactive preview web views: the preview
/// (`BaseEmailWebView`) and the snapshot render (`EmailPreviewSnapshotRenderSession`)
/// (architecture review 2026-11, `web-content-rendering#6`). They wrote the same rule inline twice,
/// without the scheme screen the reader runs first. A preview loads its own document and nothing
/// else: only an `.other` or `.reload` navigation, and never one to a refused scheme
/// (`EmailNavigationSchemeScreen`), whatever its type. A link the user taps, a form, a back or
/// forward navigation are all cancelled: a preview opens nothing (its card opens the reader).
///
/// The gap was inert while markup strips `meta`, `iframe`, `script` and `form` and the CSP forbids
/// scripts, frames and form actions; the screen keeps a `javascript:` or `file:` navigation from
/// ever loading in a preview if one of those stops holding. It must never take on the reader's
/// permissive tail (`FullInteractiveEmailWebView.navigationDecision`'s final allow, data-detector
/// taps, opening links externally).
enum EmailPreviewNavigationPolicy {
    static func allows(navigationType: WKNavigationType, url: URL?) -> Bool {
        if let url, EmailNavigationSchemeScreen.refuses(url) {
            return false
        }
        return navigationType == .other || navigationType == .reload
    }
}

/// The URL schemes no email web view navigates to, for any navigation type: script URLs and local
/// files. Shared by the reader's policy (`FullInteractiveEmailWebView.navigationDecision`) and the
/// previews' (`EmailPreviewNavigationPolicy`). `cid:` is not refused: `CIDSchemeHandler` serves it.
enum EmailNavigationSchemeScreen {
    static let refusedSchemes: Set<String> = ["javascript", "vbscript", "file"]

    static func refuses(_ url: URL) -> Bool {
        refusedSchemes.contains(url.scheme?.lowercased() ?? "")
    }
}
