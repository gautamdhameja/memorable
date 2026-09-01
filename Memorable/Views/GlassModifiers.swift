import SwiftUI

struct GlassSearchBarModifier: ViewModifier {
    var cornerRadius: CGFloat = Celestial.sharedCornerRadius

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Celestial.Colors.surfaceContainer.opacity(0.34)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .celestialMaterialSurface(
                    cornerRadius: cornerRadius,
                    tint: Celestial.Colors.surfaceContainer.opacity(0.58),
                    stroke: Celestial.Colors.primaryDim.opacity(0.30)
                )
        }
    }
}

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var tint: Color = Celestial.Colors.surfaceContainerLow.opacity(0.30)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .celestialMaterialSurface(
                    cornerRadius: cornerRadius,
                    tint: tint.opacity(0.72),
                    stroke: Celestial.Colors.hairline
                )
        }
    }
}

struct GlassCircleModifier: ViewModifier {
    var tint: Color = Celestial.Colors.surfaceContainerLow.opacity(0.30)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: .circle
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .background(tint.opacity(0.74), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.75)
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
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(tint, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                )
        }
    }
}

private extension View {
    func celestialMaterialSurface(
        cornerRadius: CGFloat,
        tint: Color,
        stroke: Color
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return background(.ultraThinMaterial, in: shape)
            .background(tint, in: shape)
            .overlay(shape.stroke(stroke, lineWidth: 0.75))
    }
}
