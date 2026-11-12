import SwiftUI

extension View {
    /// Shows a conversation's name in a capsule in a bar along the top of this view, under the
    /// window's toolbar: the lower half of the Mac chat header, whose upper half is the avatar
    /// in the toolbar (`MacChatHeaderNameBar`, `ChatHeaderPolicy`).
    ///
    /// `metrics` is nil for a chat whose header style has no such bar
    /// (`ChatHeaderPolicy.nameBarMetrics`), and then nothing is added. Changes nothing on iOS,
    /// where a chat's name is its navigation title.
    func macChatHeaderNameBar(
        metrics: ChatHeaderMetrics?,
        name: String,
        opensParticipants: Bool,
        onOpenParticipants: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        modifier(
            MacChatHeaderNameBarModifier(
                metrics: metrics,
                name: name,
                opensParticipants: opensParticipants,
                onOpenParticipants: onOpenParticipants
            )
        )
        #else
        self
        #endif
    }
}
