import SwiftUI

struct GlassSearchBarModifier: ViewModifier {
    var cornerRadius: CGFloat = Celestial.sharedCornerRadius

    func body(content: Content) -> some View {
        content
            .background(Celestial.Colors.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Celestial.Colors.primaryDim.opacity(0.34), lineWidth: 1)
            )
    }
}

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(Celestial.Colors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Celestial.Colors.hairline, lineWidth: 1)
            )
    }
}
