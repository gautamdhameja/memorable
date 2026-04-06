import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool

    @State private var currentPage = 0

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            TabView(selection: $currentPage) {
                onboardingPage(
                    icon: "sparkle.magnifyingglass",
                    title: "Search by Memory",
                    description: "Describe what you remember and find the exact photo. \"Birthday cake with candles\", \"sunset at the beach\", \"my dog playing\".",
                    tag: 0
                )
                onboardingPage(
                    icon: "lock.shield",
                    title: "100% Private",
                    description: "All AI processing happens on your device. Your photos never leave your phone. No cloud. No accounts. No tracking.",
                    tag: 1
                )
                onboardingPage(
                    icon: "cpu",
                    title: "One-Time Setup",
                    description: "Memorable needs to scan your photo library once to build a search index. This takes a few minutes and only happens once.",
                    tag: 2,
                    showGetStarted: true
                )
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
        .preferredColorScheme(.dark)
    }

    private func onboardingPage(icon: String, title: String, description: String, tag: Int, showGetStarted: Bool = false) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(Celestial.Colors.primaryDim)

            Text(title)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(Celestial.Colors.onSurface)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            if showGetStarted {
                Button(action: {
                    UserDefaults.standard.set(true, forKey: AppKeys.onboardingComplete)
                    withAnimation { isComplete = true }
                }) {
                    Text("Get Started")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Celestial.Colors.primaryContainer)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            } else {
                Spacer()
                    .frame(height: 100)
            }
        }
        .tag(tag)
    }
}
