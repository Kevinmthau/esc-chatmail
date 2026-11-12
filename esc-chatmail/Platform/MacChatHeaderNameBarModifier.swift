#if os(macOS)
import SwiftUI

/// Puts `MacChatHeaderNameBar` along the top of a chat's transcript, under the window's toolbar
/// (`View.macChatHeaderNameBar`).
///
/// `safeAreaBar`, not an overlay and not a taller toolbar item:
/// - The toolbar is 52 points tall and does not grow, and a view the chat column draws up into
///   those 52 points gets no clicks there; they go to the toolbar. So the name cannot sit in the
///   toolbar with the avatar, and has a bar of its own under it.
/// - The bar is the top of the transcript's safe area, so the transcript's first row starts
///   under it and its rows scroll up beneath it, where `safeAreaBar` (unlike `safeAreaInset`)
///   extends the scroll edge effect. Measured in the spike; the effect itself has not been seen.
///
/// The bar adds `ChatHeaderMetrics.nameBarHeight` to the transcript's top inset, the same for
/// every chat, from the moment the chat mounts. Whether there is a bar is fixed by the chat's
/// header style (`ChatHeaderPolicy.nameBarMetrics`), so this branch never changes for a given
/// chat and the transcript under it keeps one identity.
struct MacChatHeaderNameBarModifier: ViewModifier {
    /// Nil for a chat with no name bar.
    let metrics: ChatHeaderMetrics?
    let name: String
    let opensParticipants: Bool
    let onOpenParticipants: () -> Void

    func body(content: Content) -> some View {
        if let metrics {
            // No spacing: the inset is the bar's height and nothing else.
            content.safeAreaBar(edge: .top, spacing: 0) {
                MacChatHeaderNameBar(
                    metrics: metrics,
                    name: name,
                    opensParticipants: opensParticipants,
                    onOpenParticipants: onOpenParticipants
                )
            }
        } else {
            content
        }
    }
}
#endif
