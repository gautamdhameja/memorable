import SwiftUI

struct GlassSearchBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(
                    Celestial.glassBackground
                        .background(.ultraThinMaterial)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Celestial.Colors.outlineVariant.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

struct GlassBadgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
    }
}

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(Celestial.Colors.surfaceVariant.opacity(0.4))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
