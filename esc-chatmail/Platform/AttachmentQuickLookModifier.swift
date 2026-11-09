import SwiftUI
#if os(macOS)
// `.quickLookPreview` comes from SwiftUI's QuickLook overlay.
import QuickLook
#endif

/// Shows `AttachmentGridView`'s Quick Look presentation and clears it when Quick Look closes.
///
/// iOS presents Quick Look as its own UIKit modal rather than in a SwiftUI sheet: inside a sheet
/// it had no Done button and a drag on the document only scrolled it (see
/// `QuickLookPreviewController`). Its dismissal clears the state, and so does a presentation that
/// never appeared, or the task would present it unprompted when the view reappears. Neither may
/// clear a newer tap's presentation (`QuickLookPresentationPolicy`).
///
/// The Mac uses SwiftUI's `.quickLookPreview`, which shows the system Quick Look panel and pages
/// through the presentation's files there. Closing the panel clears the selection, which clears
/// the presentation.
struct AttachmentQuickLookModifier: ViewModifier {
    @Binding var presentation: QuickLookPresentation?
    #if os(macOS)
    @State private var selectedURL: URL?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .task(id: presentation?.id) {
                guard let attempted = presentation else { return }
                let outcome = await QuickLookPreviewController.present(attempted) {
                    guard QuickLookPresentationPolicy.shouldClearOnDismiss(
                        of: attempted.id,
                        current: presentation?.id
                    ) else { return }
                    presentation = nil
                }
                if outcome == .noPresenter {
                    Log.error("Quick Look found no presenter for attachment preview", category: .ui)
                }
                guard QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
                    attempted.id,
                    outcome: outcome,
                    current: presentation?.id
                ) else { return }
                presentation = nil
            }
        #else
        content
            .quickLookPreview($selectedURL, in: presentation?.itemURLs ?? [])
            .onChange(of: presentation?.id, initial: true) {
                selectedURL = presentation?.selectedItemURL
            }
            .onChange(of: selectedURL) { _, newURL in
                guard newURL == nil, presentation != nil else { return }
                presentation = nil
            }
        #endif
    }
}
