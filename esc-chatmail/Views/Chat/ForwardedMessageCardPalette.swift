import SwiftUI

/// The forwarded-message card's colors (`ForwardedMessageCard`), by whose bubble it sits on and
/// whether the person asked for more contrast (architecture review 2026-11,
/// gap-accessibility-architecture#3).
///
/// On the user's own blue bubble the card's secondary and tertiary lines are white at 0.82 and
/// 0.66 over a white 0.14 fill, about 3.2:1 and 2.6:1, below 4.5:1 for text of 11 to 13 points.
/// That stays the standard look; with Increase Contrast those lines are opaque white, and the
/// fill that lowered them is dropped for a firmer stroke. The received card's colors are system
/// colors that already adapt, so only its tertiary line loses its extra opacity. Colors only:
/// nothing here changes the card's layout or a row's height.
struct ForwardedMessageCardPalette: Equatable {
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let cardBackground: Color
    let stroke: Color

    static func palette(isFromMe: Bool, contrast: ColorSchemeContrast) -> ForwardedMessageCardPalette {
        switch (isFromMe, contrast) {
        case (true, .increased):
            return ForwardedMessageCardPalette(
                primaryText: .white,
                secondaryText: .white,
                tertiaryText: .white,
                cardBackground: .clear,
                stroke: Color.white.opacity(0.6)
            )
        case (true, _):
            return ForwardedMessageCardPalette(
                primaryText: .white,
                secondaryText: Color.white.opacity(0.82),
                tertiaryText: Color.white.opacity(0.66),
                cardBackground: Color.white.opacity(0.14),
                stroke: Color.white.opacity(0.12)
            )
        case (false, .increased):
            return ForwardedMessageCardPalette(
                primaryText: .primary,
                secondaryText: Color.secondary,
                tertiaryText: Color.secondary,
                cardBackground: Color.systemBackground.opacity(0.68),
                stroke: Color.primary.opacity(0.08)
            )
        case (false, _):
            return ForwardedMessageCardPalette(
                primaryText: .primary,
                secondaryText: Color.secondary,
                tertiaryText: Color.secondary.opacity(0.84),
                cardBackground: Color.systemBackground.opacity(0.68),
                stroke: Color.primary.opacity(0.08)
            )
        }
    }
}
