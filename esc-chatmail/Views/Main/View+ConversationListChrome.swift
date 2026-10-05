import SwiftUI

/// iOS 26 adaptors for the conversation list's bottom chrome. On iOS 26 the
/// bar matches Messages — Liquid Glass controls over a scroll edge effect —
/// while earlier systems keep the pre-iOS 26 surfaces (opaque fill, hairline,
/// shadow) and plain `safeAreaInset`. The bar's layout and metrics live in
/// `ConversationListView` and are shared by both.
extension View {
    /// Pins `bar` to the bottom edge. On iOS 26 `safeAreaBar` also extends the
    /// scroll edge effect beneath it, so rows soften as they slide under the
    /// search field the way Messages' do; `safeAreaInset` (earlier systems)
    /// insets the content without that effect.
    @ViewBuilder
    func conversationListBottomBar<Bar: View>(_ bar: Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) { bar }
        } else {
            safeAreaInset(edge: .bottom) { bar }
        }
    }

    /// Backs a bottom-bar control with Liquid Glass on iOS 26 — interactive
    /// (press feedback) for buttons, plain for the search field, where a tap
    /// places the caret — and with `legacyGlassSurface` on earlier systems.
    @ViewBuilder
    func conversationListGlassBackground<S: InsettableShape>(
        _ shape: S,
        isInteractive: Bool = true,
        legacyMaterial: Material? = nil
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(isInteractive), in: shape)
        } else {
            background(legacyGlassSurface(shape, material: legacyMaterial))
        }
    }

    /// Groups neighbouring glass controls on iOS 26: glass cannot sample other
    /// glass, so Apple has nearby glass elements share one
    /// `GlassEffectContainer` to render consistently. Spacing 0 keeps the
    /// shapes from blending into one another across their gap — Messages'
    /// search field and compose button stay separate. Earlier systems draw no
    /// glass, so the content passes through.
    @ViewBuilder
    func conversationListGlassGroup() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { self }
        } else {
            self
        }
    }
}

/// Pre-iOS 26 "glass" chrome for the bottom-bar surfaces: a 0.95-opacity
/// system-background fill, a 0.5pt gray hairline stroke, and a soft drop
/// shadow. Only the selection action bar passes `material:` (layering
/// `.thinMaterial` over the fill); the search bar and compose button are
/// deliberately material-free, matching the pre-refactor styling.
private func legacyGlassSurface<S: InsettableShape>(_ shape: S, material: Material?) -> some View {
    ZStack {
        shape
            .fill(Color(UIColor.systemBackground).opacity(0.95))
        if let material {
            shape
                .fill(material)
        }
    }
    .overlay(
        shape
            .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
}
