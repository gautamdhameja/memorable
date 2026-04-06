import SwiftUI

struct UpgradeView: View {
    @ObservedObject var proManager = ProManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(Celestial.Colors.primaryDim)

                Text("Unlock Memorable Pro")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Celestial.Colors.onSurface)

                VStack(alignment: .leading, spacing: 14) {
                    featureRow(icon: "infinity", text: "Unlimited photo indexing")
                    featureRow(icon: "sparkle.magnifyingglass", text: "Find Similar Photos")
                    featureRow(icon: "minus.circle", text: "Negative search filters")
                    featureRow(icon: "folder.badge.plus", text: "Custom folder sources")
                    featureRow(icon: "brain", text: "Smart query understanding")
                    featureRow(icon: "calendar.badge.clock", text: "Date & location search boost")
                }
                .padding(.horizontal, 32)

                Text("One-time purchase. No subscription.")
                    .font(.caption)
                    .foregroundStyle(Celestial.Colors.outline)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        Task {
                            await proManager.purchase()
                            if proManager.isPro { Haptics.success() }
                        }
                    }) {
                        Group {
                            if let product = proManager.product {
                                Text("Upgrade for \(product.displayPrice)")
                            } else {
                                Text("Upgrade to Pro")
                            }
                        }
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Celestial.Colors.primaryContainer)
                        .clipShape(Capsule())
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
                                .font(.subheadline)
                                .foregroundStyle(Celestial.Colors.primaryDim)
                        }
                    }
                    .disabled(proManager.isRestoring)

                    if let message = proManager.restoreMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.contains("success") ? Celestial.Colors.primaryDim : Celestial.Colors.onSurfaceVariant)
                    }

                    if let error = proManager.purchaseError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Celestial.Colors.error)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .padding(10)
                    .background(Celestial.Colors.surfaceVariant.opacity(0.5))
                    .clipShape(Circle())
            }
            .padding(16)
        }
        .onChange(of: proManager.isPro) {
            if proManager.isPro { dismiss() }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Celestial.Colors.primaryDim)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurface)
        }
    }
}
