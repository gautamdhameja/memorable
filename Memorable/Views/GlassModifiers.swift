import SwiftUI

struct GlassSearchBarModifier: ViewModifier {
    var cornerRadius: CGFloat = Celestial.sharedCornerRadius

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Celestial.Colors.surfaceContainer.opacity(0.34)).interactive(),
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
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(interactive),
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
    var interactive = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(interactive),
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
                    tint: tint.opacity(0.13),
                    interactive: false
                )
            )
            .accessibilityHidden(true)
    }
}

struct CelestialButtonStyle: ButtonStyle {
    var tint: Color = Celestial.Colors.primaryDim
    var foreground: Color = Celestial.Colors.onPrimaryContainer

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Celestial.Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .modifier(
                GlassPanelModifier(
                    cornerRadius: 13,
                    tint: tint.opacity(configuration.isPressed ? 0.54 : 0.44),
                    interactive: true
                )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CelestialSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Celestial.Colors.primaryDim

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

struct GlassCapsuleModifier: ViewModifier {
    var tint: Color
    var interactive = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(interactive),
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
