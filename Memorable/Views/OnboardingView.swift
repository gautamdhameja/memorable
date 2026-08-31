import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Binding var startIndexAfterCompletion: Bool

    @State private var currentPage = 0

    var body: some View {
        ZStack {
            CelestialBackdrop()

            TabView(selection: $currentPage) {
                searchByMemoryPage.tag(0)
                privacyPage.tag(1)
                setupPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .preferredColorScheme(.dark)
    }

    private var searchByMemoryPage: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                MemoryReelHero()
                    .frame(height: min(258, max(218, proxy.size.height * 0.31)))
                    .padding(.top, max(22, proxy.safeAreaInsets.top + 10))

                HStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Celestial.Colors.primaryDim)
                    Text("sunset at the beach last summer")
                        .font(.subheadline)
                        .foregroundStyle(Celestial.Colors.onSurface)
                        .lineLimit(1)
                }
                .padding(.horizontal, 15)
                .frame(height: 50)
                .modifier(GlassSearchBarModifier(cornerRadius: 13))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Example search: sunset at the beach last summer")

                Spacer().frame(height: max(34, proxy.size.height * 0.055))

                VStack(alignment: .leading, spacing: -2) {
                    Text("Search your photos")
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("by what you remember")
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Celestial.Colors.primary, Celestial.Colors.amber],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                    .font(.largeTitle.bold())
                    .tracking(-0.8)

                (Text("Describe the moment. ")
                    .foregroundColor(Celestial.Colors.onSurfaceVariant)
                    + Text("No tags or albums to maintain.")
                    .foregroundColor(Celestial.Colors.primary.opacity(0.88)))
                    .font(.body)
                    .lineSpacing(5)
                    .padding(.top, 16)

                Spacer()

                pageFooter(primaryTitle: "Continue") {
                    withAnimation(.easeInOut(duration: 0.25)) { currentPage = 1 }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 10)
        }
    }

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 122)

            VStack(alignment: .leading, spacing: -2) {
                Text("Your photos stay")
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text("on this iPhone")
                    .foregroundStyle(Celestial.Colors.primary)
            }
                .font(.largeTitle.bold())
                .tracking(-0.8)

            (Text("No developer account or tracking. ")
                .foregroundColor(Celestial.Colors.primary.opacity(0.88))
                + Text("No automatic photo uploads.")
                .foregroundColor(Celestial.Colors.onSurfaceVariant))
                .font(.body)
                .padding(.top, 16)

            VStack(spacing: 0) {
                privacyRow(number: "01", text: "Indexing and search run on this iPhone")
                privacyRow(number: "02", text: "Apple resolves photo coordinates into place names")
                privacyRow(number: "03", text: "Delete the index any time")
                CelestialHairline()
            }
            .padding(.horizontal, 16)
            .modifier(GlassPanelModifier(cornerRadius: 18))
            .padding(.top, 54)

            Text("Search works offline after place names have been resolved.")
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .lineSpacing(4)
                .padding(.top, 26)

            Spacer()

            pageFooter(primaryTitle: "Continue") {
                withAnimation(.easeInOut(duration: 0.25)) { currentPage = 2 }
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle()
                    .stroke(Celestial.Colors.hairline, lineWidth: 1)
                    .frame(width: 150, height: 150)
                Circle()
                    .stroke(
                        Celestial.Colors.primaryDim.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 8])
                    )
                    .frame(width: 106, height: 106)
                CelestialGlassIcon(
                    systemName: "magnifyingglass",
                    size: 64
                )
                Circle()
                    .fill(Celestial.Colors.amber)
                    .frame(width: 6, height: 6)
                    .offset(x: 75)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)

            VStack(alignment: .leading, spacing: -2) {
                Text("Make local media")
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text("searchable")
                    .foregroundStyle(Celestial.Colors.amber)
            }
                .font(.title.bold())
                .tracking(-0.7)
                .padding(.top, 62)

            (Text("Indexing runs on this iPhone. ")
                .foregroundColor(Celestial.Colors.onSurfaceVariant)
                + Text("Photos become searchable as it goes.")
                .foregroundColor(Celestial.Colors.amber.opacity(0.90)))
                .font(.body)
                .lineSpacing(5)
                .padding(.top, 16)

            VStack(spacing: 0) {
                setupRow(label: "Processing", value: "On device")
                setupRow(label: "Search availability", value: "Progressive")
                setupRow(label: "Free tier indexes", value: "First 500 items", accent: true)
                CelestialHairline()
            }
            .padding(.horizontal, 16)
            .modifier(GlassPanelModifier(cornerRadius: 18))
            .padding(.top, 32)

            Spacer()

            Text("Photos and search text stay on this iPhone unless you choose Share")
                .font(.caption)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)

            Button {
                startIndexAfterCompletion = true
                completeOnboarding()
            } label: {
                Text("Build Search Index")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(
                CelestialButtonStyle(
                    tint: Celestial.Colors.amber,
                    foreground: Celestial.Colors.surfaceDim
                )
            )

            Button("Not now") {
                startIndexAfterCompletion = false
                completeOnboarding()
            }
            .font(.body.weight(.medium))
            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    private func privacyRow(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(number)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(Celestial.Colors.primaryDim)
            Text(text)
                .font(.body)
                .foregroundStyle(Celestial.Colors.onSurface)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 19)
        .overlay(alignment: .top) { CelestialHairline() }
    }

    private func setupRow(label: String, value: String, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(accent ? Celestial.Colors.amber : Celestial.Colors.onSurface)
        }
        .font(.subheadline)
        .padding(.vertical, 15)
        .overlay(alignment: .top) { CelestialHairline() }
    }

    private func pageFooter(primaryTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(
                            index == currentPage
                                ? pageAccent
                                : Celestial.Colors.onSurface.opacity(0.20)
                        )
                        .frame(width: 20, height: 3)
                }
            }

            Button(action: action) {
                Text(primaryTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CelestialButtonStyle())
        }
    }

    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.25)) { isComplete = true }
    }

    private var pageAccent: Color {
        currentPage == 2 ? Celestial.Colors.amber : Celestial.Colors.primaryDim
    }
}

private struct MemoryReelHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Celestial.Colors.primaryDim.opacity(0.13))
                .frame(width: 250, height: 138)
                .blur(radius: 28)

            AbstractMemoryCard(
                palette: .alpine,
                isFocused: false
            )
            .frame(width: 92, height: 122)
            .rotationEffect(.degrees(revealed ? -10 : -2))
            .offset(x: revealed ? -88 : -20, y: 13)
            .opacity(revealed ? 0.82 : 0)

            AbstractMemoryCard(
                palette: .evening,
                isFocused: false
            )
            .frame(width: 92, height: 122)
            .rotationEffect(.degrees(revealed ? 10 : 2))
            .offset(x: revealed ? 88 : 20, y: 13)
            .opacity(revealed ? 0.82 : 0)

            AbstractMemoryCard(
                palette: .goldenHour,
                isFocused: true
            )
            .frame(width: 120, height: 154)
            .scaleEffect(revealed ? 1 : 0.92)
            .offset(y: -4)
            .shadow(color: Celestial.Colors.amber.opacity(0.18), radius: 24, y: 10)

            searchLens
                .offset(x: 63, y: 49)
                .scaleEffect(revealed ? 1 : 0.5)
                .opacity(revealed ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.spring(response: 0.72, dampingFraction: 0.82)) {
                    revealed = true
                }
            }
        }
    }

    private var searchLens: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(.clear)
                .frame(width: 62, height: 62)
                .modifier(
                    GlassCircleModifier(
                        tint: Celestial.Colors.primaryDim.opacity(0.20)
                    )
                )
                .overlay {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Celestial.Colors.primary, Celestial.Colors.amber],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .overlay {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Celestial.Colors.onSurface)
                }

            Circle()
                .fill(Celestial.Colors.amber)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Celestial.Colors.background, lineWidth: 2))
                .offset(x: -1, y: 2)
        }
        .shadow(color: Celestial.Colors.primaryDim.opacity(0.24), radius: 18, y: 8)
    }
}

private struct AbstractMemoryCard: View {
    enum Palette {
        case alpine
        case goldenHour
        case evening

        var colors: [Color] {
            switch self {
            case .alpine:
                return [
                    Color(red: 73 / 255, green: 126 / 255, blue: 164 / 255),
                    Color(red: 24 / 255, green: 42 / 255, blue: 66 / 255),
                ]
            case .goldenHour:
                return [
                    Color(red: 80 / 255, green: 138 / 255, blue: 186 / 255),
                    Color(red: 234 / 255, green: 172 / 255, blue: 99 / 255),
                    Color(red: 73 / 255, green: 45 / 255, blue: 55 / 255),
                ]
            case .evening:
                return [
                    Color(red: 83 / 255, green: 75 / 255, blue: 139 / 255),
                    Color(red: 31 / 255, green: 31 / 255, blue: 62 / 255),
                ]
            }
        }

        var light: Color {
            switch self {
            case .alpine: return Celestial.Colors.primary
            case .goldenHour: return Celestial.Colors.amber
            case .evening: return Color(red: 201 / 255, green: 163 / 255, blue: 1)
            }
        }
    }

    let palette: Palette
    let isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                LinearGradient(
                    colors: palette.colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(palette.light.opacity(0.88))
                    .frame(width: width * 0.34, height: width * 0.34)
                    .blur(radius: palette == .goldenHour ? 1 : 5)
                    .offset(x: width * 0.18, y: -height * 0.17)

                Canvas { context, size in
                    var distant = Path()
                    distant.move(to: CGPoint(x: 0, y: size.height * 0.62))
                    distant.addCurve(
                        to: CGPoint(x: size.width, y: size.height * 0.58),
                        control1: CGPoint(x: size.width * 0.28, y: size.height * 0.35),
                        control2: CGPoint(x: size.width * 0.72, y: size.height * 0.78)
                    )
                    distant.addLine(to: CGPoint(x: size.width, y: size.height))
                    distant.addLine(to: CGPoint(x: 0, y: size.height))
                    distant.closeSubpath()
                    context.fill(
                        distant,
                        with: .color(Celestial.Colors.surfaceContainerHigh.opacity(0.68))
                    )

                    var foreground = Path()
                    foreground.move(to: CGPoint(x: 0, y: size.height * 0.78))
                    foreground.addCurve(
                        to: CGPoint(x: size.width, y: size.height * 0.72),
                        control1: CGPoint(x: size.width * 0.32, y: size.height * 0.56),
                        control2: CGPoint(x: size.width * 0.66, y: size.height * 0.92)
                    )
                    foreground.addLine(to: CGPoint(x: size.width, y: size.height))
                    foreground.addLine(to: CGPoint(x: 0, y: size.height))
                    foreground.closeSubpath()
                    context.fill(
                        foreground,
                        with: .color(Celestial.Colors.surfaceDim.opacity(0.88))
                    )
                }

                LinearGradient(
                    colors: [.white.opacity(0.20), .clear, .black.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if isFocused {
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Celestial.Colors.amber)
                                .frame(width: 5, height: 5)
                            Text("MATCH")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(.white.opacity(0.90))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .modifier(
                            GlassCapsuleModifier(
                                tint: Color.black.opacity(0.12),
                                interactive: false
                            )
                        )
                        .padding(.bottom, 9)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(
                    isFocused
                        ? Celestial.Colors.primary.opacity(0.68)
                        : Color.white.opacity(0.14),
                    lineWidth: isFocused ? 1.2 : 0.75
                )
        }
        .shadow(color: .black.opacity(0.34), radius: 14, y: 9)
    }
}
