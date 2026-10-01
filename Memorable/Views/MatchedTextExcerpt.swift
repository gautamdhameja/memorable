import SwiftUI

struct MatchedTextExcerpt: View {
    let match: OCRTextMatch
    var reservesSpace = false

    var body: some View {
        (Text(match.before) + Text(match.phrase).bold().foregroundColor(Celestial.Colors.primary) + Text(match.after))
            .font(Celestial.Typography.caption)
            .lineLimit(3, reservesSpace: reservesSpace)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Matched text: \(match.excerpt)")
    }
}
