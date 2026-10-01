import SwiftUI

struct UpgradeView: View {
    @ObservedObject var proManager = ProManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CelestialBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Capsule()
                        .fill(Celestial.Colors.onSurface.opacity(0.18))
                        .frame(width: 34, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)

                    Text("MEMORABLE PRO")
                        .font(Celestial.Typography.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Celestial.Colors.amber)
                        .padding(.top, 26)

                    Text("Unlock your whole library")
                        .font(Celestial.Typography.title)
                        .foregroundStyle(Celestial.Colors.onSurface)
                        .padding(.top, 12)

                    Text("Move beyond the free 500-item index and get every way Memorable can help you find the right photo.")
                        .font(Celestial.Typography.supporting)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    VStack(spacing: 0) {
                        proFeature(
                            "Search everything",
                            detail: "Every locally available photo and video, including folders",
                            icon: "photo.stack",
                            isFirst: true
                        )
                        proFeature(
                            "Find exactly what you mean",
                            detail: "Similar photos, exclusions, natural dates, and places",
                            icon: "sparkles"
                        )
                        proFeature(
                            "Clean up duplicates",
                            detail: "Review near-identical photos safely before removing a copy",
                            icon: "square.on.square"
                        )
                    }
                    .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
                    .modifier(
                        GlassPanelModifier(
                            cornerRadius: 20,
                            tint: Celestial.Colors.amber.opacity(0.08)
                        )
                    )
                    .padding(.top, Celestial.Spacing.contentGap)
                }
                .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            purchaseFooter
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
            }
            .celestialGlassCircleButtonStyle(
                tint: Celestial.Colors.surfaceContainerLow.opacity(0.30),
                foreground: Celestial.Colors.onSurfaceVariant
            )
            .accessibilityLabel("Close")
            .padding(Celestial.Spacing.surfaceHorizontalInset)
        }
        .onChange(of: proManager.isPro) {
            if proManager.isPro { dismiss() }
        }
        .task {
            await proManager.loadProduct()
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            if proManager.hasProductLoadFailed {
                Text("Couldn't reach the App Store. Check your connection and try again.")
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            }

            if let message = proManager.restoreMessage {
                Text(message)
                    .foregroundStyle(
                        message.contains("success")
                            ? Celestial.Colors.primaryDim
                            : Celestial.Colors.onSurfaceVariant
                    )
            }

            if let error = proManager.purchaseError {
                Text(error)
                    .foregroundStyle(Celestial.Colors.error)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("One-time purchase")
                        .font(Celestial.Typography.captionStrong)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("No subscription")
                        .font(Celestial.Typography.micro)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }

                Spacer(minLength: 8)

                Button(action: {
                    Task { await proManager.restorePurchases() }
                }) {
                    HStack(spacing: 6) {
                        if proManager.isRestoring {
                            ProgressView()
                                .tint(Celestial.Colors.amber)
                                .controlSize(.small)
                        }
                        Text(proManager.isRestoring ? "Restoring..." : "Restore")
                    }
                }
                .celestialGlassCapsuleButtonStyle(
                    tint: Celestial.Colors.amber.opacity(0.18),
                    foreground: Celestial.Colors.amber
                )
                .disabled(proManager.isCommerceBusy)
                .accessibilityLabel(
                    proManager.isRestoring ? "Restoring Purchase" : "Restore Purchase"
                )
            }

            Button(action: {
                Task {
                    await proManager.purchase()
                    if proManager.isPro { Haptics.success() }
                }
            }) {
                HStack(spacing: 10) {
                    if proManager.isPurchasing || proManager.isLoadingProduct {
                        ProgressView()
                            .tint(Celestial.Colors.onPrimaryContainer)
                            .controlSize(.regular)
                    }
                    if proManager.isPurchasing {
                        Text("Purchasing Pro...")
                    } else if proManager.isLoadingProduct {
                        Text("Connecting to App Store...")
                    } else if let product = proManager.product {
                        Text("Unlock Pro · \(product.displayPrice)")
                    } else if proManager.hasProductLoadFailed {
                        Text("Try Again")
                    } else {
                        Text("Upgrade to Pro")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .celestialPrimaryButtonStyle(
                tint: Celestial.Colors.amber,
                foreground: Celestial.Colors.surfaceDim
            )
            .disabled(proManager.isCommerceBusy)
            .accessibilityLabel(
                proManager.isPurchasing ? "Purchasing Pro" : "Upgrade to Memorable Pro"
            )
        }
        .font(Celestial.Typography.caption)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { CelestialHairline() }
    }

    private func proFeature(
        _ title: String,
        detail: String,
        icon: String,
        isFirst: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CelestialGlassIcon(
                systemName: icon,
                tint: Celestial.Colors.amber,
                size: 32
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Celestial.Typography.supportingEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text(detail)
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.outline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
        // Dividers sit between rows only, not along the panel's border.
        .overlay(alignment: .top) {
            if !isFirst { CelestialHairline() }
        }
    }
}
