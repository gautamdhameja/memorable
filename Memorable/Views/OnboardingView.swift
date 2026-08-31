import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Binding var startIndexAfterCompletion: Bool

    @State private var currentPage = 0

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

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
                SemanticConstellationHero()
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
                .background(Celestial.Colors.surfaceContainer.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Celestial.Colors.primaryDim.opacity(0.42), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Example search: sunset at the beach last summer")

                Spacer().frame(height: max(34, proxy.size.height * 0.055))

                Text("Search your photos\nby what you remember")
                    .font(.largeTitle.bold())
                    .tracking(-0.8)
                    .foregroundStyle(Celestial.Colors.onSurface)

                Text("Describe the moment. No tags, no albums to keep up with.")
                    .font(.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
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

            Text("Your photos stay\non this iPhone")
                .font(.largeTitle.bold())
                .tracking(-0.8)
                .foregroundStyle(Celestial.Colors.onSurface)

            Text("No developer account, tracking, or automatic photo uploads.")
                .font(.body)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .padding(.top, 16)

            VStack(spacing: 0) {
                privacyRow(number: "01", text: "Indexing and search run on this iPhone")
                privacyRow(number: "02", text: "Apple resolves photo coordinates into place names")
                privacyRow(number: "03", text: "Delete the index any time")
                CelestialHairline()
            }
            .padding(.top, 64)

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
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Celestial.Colors.primaryDim)
                Circle()
                    .fill(Celestial.Colors.amber)
                    .frame(width: 6, height: 6)
                    .offset(x: 75)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)

            Text("Make local media\nsearchable")
                .font(.title.bold())
                .tracking(-0.7)
                .foregroundStyle(Celestial.Colors.onSurface)
                .padding(.top, 62)

            Text("Indexing runs on this iPhone. Locally available photos become searchable as it goes.")
                .font(.body)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .lineSpacing(5)
                .padding(.top, 16)

            VStack(spacing: 0) {
                setupRow(label: "Processing", value: "On device")
                setupRow(label: "Search availability", value: "Progressive")
                setupRow(label: "Free tier indexes", value: "First 500 items", accent: true)
                CelestialHairline()
            }
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
                    .font(.headline)
                    .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Celestial.Colors.primaryDim)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

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
                        .fill(index == currentPage ? Celestial.Colors.primaryDim : Celestial.Colors.onSurface.opacity(0.20))
                        .frame(width: 20, height: 3)
                }
            }

            Button(action: action) {
                Text(primaryTitle)
                    .font(.headline)
                    .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Celestial.Colors.primaryDim)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.25)) { isComplete = true }
    }
}

private struct SemanticConstellationHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let center = CGPoint(x: width * 0.5, y: height * 0.52)
            let memoryPoints = [
                CGPoint(x: width * 0.24, y: height * 0.25),
                CGPoint(x: width * 0.78, y: height * 0.25),
                CGPoint(x: width * 0.20, y: height * 0.75),
                CGPoint(x: width * 0.80, y: height * 0.76),
            ]

            ZStack {
                Canvas { context, _ in
                    for point in memoryPoints {
                        var path = Path()
                        path.move(to: center)
                        path.addLine(to: point)
                        context.stroke(
                            path,
                            with: .color(Celestial.Colors.primaryDim.opacity(0.18)),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 6])
                        )
                    }
                }
                .opacity(revealed ? 1 : 0)

                Ellipse()
                    .stroke(Celestial.Colors.primaryDim.opacity(0.16), lineWidth: 1)
                    .frame(width: width * 0.68, height: height * 0.42)
                    .rotationEffect(.degrees(-11))

                Circle()
                    .fill(Celestial.Colors.surfaceContainer)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Circle()
                            .stroke(Celestial.Colors.primaryDim.opacity(0.72), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(Celestial.Colors.primary)
                    }
                    .shadow(color: Celestial.Colors.primaryDim.opacity(0.20), radius: 24)
                    .position(center)

                SemanticMemoryGlyph(symbol: "mountain.2.fill")
                    .position(memoryPoints[0])
                SemanticMemoryGlyph(symbol: "sun.horizon.fill", isMatch: true)
                    .position(memoryPoints[1])
                SemanticMemoryGlyph(symbol: "pawprint.fill")
                    .position(memoryPoints[2])
                SemanticMemoryGlyph(symbol: "birthday.cake.fill")
                    .position(memoryPoints[3])
            }
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.96)
        }
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.easeOut(duration: 0.65)) {
                    revealed = true
                }
            }
        }
    }
}

private struct SemanticMemoryGlyph: View {
    let symbol: String
    var isMatch = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Celestial.Colors.surfaceContainerHigh)
                .frame(width: 58, height: 58)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(
                            isMatch
                                ? Celestial.Colors.primaryDim.opacity(0.90)
                                : Celestial.Colors.hairline,
                            lineWidth: 1
                        )
                }
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(
                            isMatch
                                ? Celestial.Colors.primary
                                : Celestial.Colors.onSurfaceVariant
                        )
                }

            if isMatch {
                Circle()
                    .fill(Celestial.Colors.amber)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle().stroke(Celestial.Colors.background, lineWidth: 2)
                    }
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 62, height: 62)
    }
}
