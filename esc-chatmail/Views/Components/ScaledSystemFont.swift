import SwiftUI

/// A system font of `size` points at the default text size that grows and shrinks with
/// Dynamic Type, relative to `textStyle` (`@ScaledMetric`), for text a person types that was
/// drawn at a fixed size (architecture review 2026-11, gap-accessibility-architecture#3). On
/// the Mac, which has no Dynamic Type, it stays `size`.
///
/// A modifier with an initializer of its own, so a view that uses its memberwise initializer
/// can scale a font without a stored `@ScaledMetric`: a property wrapper that takes a wrapped
/// value is one of that initializer's parameters, which Swift 6.2 and 6.4 do not agree on for
/// a private one (CLAUDE.md, Traps).
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, relativeTo textStyle: Font.TextStyle = .body, weight: Font.Weight = .regular) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    /// `ScaledSystemFont`.
    func scaledSystemFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .body,
        weight: Font.Weight = .regular
    ) -> some View {
        modifier(ScaledSystemFont(size: size, relativeTo: textStyle, weight: weight))
    }
}
