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
                        .padding(.top, 34)

                    Text("Search more local\nphotos and videos")
                        .font(Celestial.Typography.title)
                        .foregroundStyle(Celestial.Colors.onSurface)
                        .padding(.top, 16)

                    Text("Move beyond the free 500-item index and search all photos and videos that are locally available to Memorable.")
                        .font(Celestial.Typography.body)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .lineSpacing(5)
                        .padding(.top, 14)

                    VStack(spacing: 0) {
                        proFeature("Expanded local search", detail: "Search every locally available indexed photo and video")
                        proFeature("Find similar", detail: "Start from a photo instead of a description")
                        proFeature("Negative search", detail: "Leave things out, like “beach -crowds”")
                        proFeature("Folder sources", detail: "Index photos outside the Photos library")
                        proFeature("Smarter dates and places", detail: "Understand descriptions like “last winter in Berlin”")
                        CelestialHairline()
                    }
                    .padding(.horizontal, 16)
                    .modifier(
                        GlassPanelModifier(
                            cornerRadius: 20,
                            tint: Celestial.Colors.amber.opacity(0.08)
                        )
                    )
                    .padding(.top, 30)

                    Text("One-time purchase. No subscription.")
                        .font(Celestial.Typography.caption)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)

                    Button(action: {
                        Task {
                            await proManager.purchase()
                            if proManager.isPro { Haptics.success() }
                        }
                    }) {
                        Group {
                            if proManager.isLoadingProduct {
                                ProgressView()
                                    .tint(Celestial.Colors.onPrimaryContainer)
                                    .controlSize(.regular)
                            } else if let product = proManager.product {
                                Text("Unlock Pro · \(product.displayPrice)")
                            } else {
                                Text("Upgrade to Pro")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(proManager.product == nil ? 0.5 : 1.0)
                    }
                    .buttonStyle(
                        CelestialButtonStyle(
                            tint: Celestial.Colors.amber,
                            foreground: Celestial.Colors.surfaceDim
                        )
                    )
                    .disabled(proManager.product == nil)
                    .padding(.top, 14)

                    if proManager.product == nil && !proManager.isLoadingProduct {
                        Text("Unable to connect to the App Store. Please check your connection and try again.")
                            .font(Celestial.Typography.caption)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    Button(action: {
                        Task { await proManager.restorePurchases() }
                    }) {
                        if proManager.isRestoring {
                            ProgressView()
                                .tint(Celestial.Colors.primaryDim)
                                .controlSize(.small)
                        } else {
                            Text("Restore Purchase")
                        }
                    }
                    .buttonStyle(CelestialSecondaryButtonStyle())
                    .disabled(proManager.isRestoring)

                    if let message = proManager.restoreMessage {
                        Text(message)
                            .font(Celestial.Typography.caption)
                            .foregroundStyle(message.contains("success") ? Celestial.Colors.primaryDim : Celestial.Colors.onSurfaceVariant)
                    }

                    if let error = proManager.purchaseError {
                        Text(error)
                            .font(Celestial.Typography.caption)
                            .foregroundStyle(Celestial.Colors.error)
                            .multilineTextAlignment(.center)
                    }

                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .frame(width: 38, height: 38)
                    .modifier(GlassCircleModifier())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            .padding(16)
        }
        .onChange(of: proManager.isPro) {
            if proManager.isPro { dismiss() }
        }
        .task {
            await proManager.loadProduct()
        }
    }

    private func proFeature(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Celestial.Typography.bodyEmphasized)
                .foregroundStyle(Celestial.Colors.onSurface)
            Text(detail)
                .font(Celestial.Typography.caption)
                .foregroundStyle(Celestial.Colors.outline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { CelestialHairline() }
    }
}
