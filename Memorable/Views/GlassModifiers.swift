import SwiftUI

enum CelestialGlassTokens {
    static let searchTintOpacity = 0.16
    static let panelTintOpacity = 0.18
    static let circleTintOpacity = 0.16
    static let interactiveHighlightOpacity = 0.22
    static let passiveHighlightOpacity = 0.16
    static let shadowOpacity = 0.18
}

struct GlassSearchBarModifier: ViewModifier {
    var cornerRadius: CGFloat = Celestial.sharedCornerRadius

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(
                        Celestial.Colors.surfaceContainer.opacity(
                            CelestialGlassTokens.searchTintOpacity
                        )
                    ),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .celestialGlassChrome(
                    in: shape,
                    highlightOpacity: CelestialGlassTokens.interactiveHighlightOpacity,
                    shadowRadius: 12,
                    shadowY: 5
                )
        } else {
            content
                .celestialMaterialSurface(
                    cornerRadius: cornerRadius,
                    tint: Celestial.Colors.surfaceContainer.opacity(0.42)
                )
        }
    }
}

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var tint: Color = Celestial.Colors.surfaceContainerLow.opacity(
        CelestialGlassTokens.panelTintOpacity
    )

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .celestialGlassChrome(
                    in: shape,
                    highlightOpacity: CelestialGlassTokens.passiveHighlightOpacity,
                    shadowRadius: 11,
                    shadowY: 5
                )
        } else {
            content
                .celestialMaterialSurface(
                    cornerRadius: cornerRadius,
                    tint: tint.opacity(0.62)
                )
        }
    }
}

struct GlassCircleModifier: ViewModifier {
    var tint: Color = Celestial.Colors.surfaceContainerLow.opacity(
        CelestialGlassTokens.circleTintOpacity
    )

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: .circle
                )
                .celestialGlassChrome(
                    in: Circle(),
                    highlightOpacity: CelestialGlassTokens.interactiveHighlightOpacity,
                    shadowRadius: 7,
                    shadowY: 3
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .background(tint.opacity(0.58), in: Circle())
                .celestialGlassChrome(
                    in: Circle(),
                    highlightOpacity: CelestialGlassTokens.interactiveHighlightOpacity,
                    shadowRadius: 7,
                    shadowY: 3
                )
        }
    }
}

struct CelestialGlassIcon: View {
    let systemName: String
    var tint: Color = Celestial.Colors.primaryDim
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .modifier(
                GlassCircleModifier(
                    tint: tint.opacity(0.13)
                )
            )
            .accessibilityHidden(true)
    }
}

private struct CelestialPrimaryButtonModifier: ViewModifier {
    var tint: Color = Celestial.Colors.primaryDim
    var foreground: Color = Celestial.Colors.onPrimaryContainer

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .font(Celestial.Typography.button)
                .foregroundStyle(foreground)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 13))
                .controlSize(.large)
                .tint(tint)
        } else {
            content
                .buttonStyle(
                    LegacyCelestialButtonStyle(
                        tint: tint,
                        foreground: foreground
                    )
                )
        }
    }
}

private struct CelestialSecondaryButtonModifier: ViewModifier {
    var tint: Color = Celestial.Colors.primaryDim

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .font(Celestial.Typography.button)
                .foregroundStyle(tint)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(tint)
        } else {
            content
                .buttonStyle(LegacyCelestialSecondaryButtonStyle(tint: tint))
        }
    }
}

private struct CelestialGlassCircleButtonModifier: ViewModifier {
    var tint: Color = Celestial.Colors.primaryDim
    var foreground: Color = Celestial.Colors.onSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(foreground)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(tint)
        } else {
            content
                .buttonStyle(
                    LegacyCelestialGlassCircleButtonStyle(
                        tint: tint,
                        foreground: foreground
                    )
                )
        }
    }
}

private struct CelestialGlassCapsuleButtonModifier: ViewModifier {
    var tint: Color = Celestial.Colors.primaryDim
    var foreground: Color = Celestial.Colors.onSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(foreground)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(tint)
        } else {
            content
                .buttonStyle(
                    LegacyCelestialGlassCapsuleButtonStyle(
                        tint: tint,
                        foreground: foreground
                    )
                )
        }
    }
}

private struct CelestialGlassCardButtonModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                .tint(tint)
        } else {
            content
                .buttonStyle(.plain)
                .modifier(
                    GlassPanelModifier(
                        cornerRadius: cornerRadius,
                        tint: tint
                    )
                )
        }
    }
}

extension View {
    func celestialPrimaryButtonStyle(
        tint: Color = Celestial.Colors.primaryDim,
        foreground: Color = Celestial.Colors.onPrimaryContainer
    ) -> some View {
        modifier(CelestialPrimaryButtonModifier(tint: tint, foreground: foreground))
    }

    func celestialSecondaryButtonStyle(
        tint: Color = Celestial.Colors.primaryDim
    ) -> some View {
        modifier(CelestialSecondaryButtonModifier(tint: tint))
    }

    func celestialGlassCircleButtonStyle(
        tint: Color = Celestial.Colors.primaryDim,
        foreground: Color = Celestial.Colors.onSurface
    ) -> some View {
        modifier(CelestialGlassCircleButtonModifier(tint: tint, foreground: foreground))
    }

    func celestialGlassCapsuleButtonStyle(
        tint: Color = Celestial.Colors.primaryDim,
        foreground: Color = Celestial.Colors.onSurface
    ) -> some View {
        modifier(CelestialGlassCapsuleButtonModifier(tint: tint, foreground: foreground))
    }

    func celestialGlassCardButtonStyle(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        modifier(CelestialGlassCardButtonModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

private struct LegacyCelestialButtonStyle: ButtonStyle {
    var tint: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Celestial.Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .modifier(
                GlassPanelModifier(
                    cornerRadius: 13,
                    tint: tint.opacity(configuration.isPressed ? 0.54 : 0.44)
                )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct LegacyCelestialSecondaryButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Celestial.Typography.button)
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .modifier(
                GlassCapsuleModifier(
                    tint: tint.opacity(configuration.isPressed ? 0.18 : 0.10)
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct LegacyCelestialGlassCircleButtonStyle: ButtonStyle {
    var tint: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(width: 40, height: 40)
            .modifier(GlassCircleModifier(tint: tint))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct LegacyCelestialGlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .modifier(GlassCapsuleModifier(tint: tint))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct GlassCapsuleModifier: ViewModifier {
    var tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: .capsule
                )
                .celestialGlassChrome(
                    in: Capsule(),
                    highlightOpacity: CelestialGlassTokens.interactiveHighlightOpacity,
                    shadowRadius: 7,
                    shadowY: 3
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(tint, in: Capsule())
                .celestialGlassChrome(
                    in: Capsule(),
                    highlightOpacity: CelestialGlassTokens.interactiveHighlightOpacity,
                    shadowRadius: 7,
                    shadowY: 3
                )
        }
    }
}

private extension View {
    func celestialMaterialSurface(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return background(.ultraThinMaterial, in: shape)
            .background(tint, in: shape)
            .celestialGlassChrome(
                in: shape,
                highlightOpacity: CelestialGlassTokens.passiveHighlightOpacity,
                shadowRadius: 10,
                shadowY: 4
            )
    }

    func celestialGlassChrome<S: Shape>(
        in shape: S,
        highlightOpacity: Double,
        shadowRadius: CGFloat,
        shadowY: CGFloat
    ) -> some View {
        overlay {
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(highlightOpacity),
                            Celestial.Colors.primary.opacity(highlightOpacity * 0.36),
                            Color.white.opacity(highlightOpacity * 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        }
        .shadow(
            color: Color.black.opacity(CelestialGlassTokens.shadowOpacity),
            radius: shadowRadius,
            y: shadowY
        )
    }
}
