import SwiftUI
import Photos

struct SearchResultsViewer: View {
    let initialResult: SearchResult
    let allResults: [SearchResult]
    var searchEngine: SearchEngine? = nil

    @State private var currentIndex: Int = 0
    @State private var showControls: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(allResults.enumerated()), id: \.element.id) { index, result in
                    ZoomableAsyncImage(result: result)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Controls overlay
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        Spacer()
                        if allResults.count > 1 {
                            Text("\(currentIndex + 1) of \(allResults.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Button(action: { shareCurrentPhoto() }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    // Bottom info bar
                    if currentIndex < allResults.count {
                        let result = allResults[currentIndex]
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let date = result.creationDate {
                                    Text(date.formatted(date: .long, time: .shortened))
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(.white)
                                }
                                Text("\(Int(result.score * 100))% match")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            currentIndex = allResults.firstIndex(where: { $0.id == initialResult.id }) ?? 0
        }
        .onTapGesture(count: 1) {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        }
        .gesture(
            DragGesture(minimumDistance: 80)
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    }
                }
        )
    }

    private func shareCurrentPhoto() {
        guard currentIndex < allResults.count else { return }
        let result = allResults[currentIndex]
        guard let asset = PhotoLibrary.getAsset(by: result.localIdentifier) else { return }

        Task {
            guard let image = await PhotoLibrary.loadImage(
                for: asset,
                targetSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))
            ) else { return }

            await MainActor.run {
                let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController { topVC = presented }
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }
        }
    }
}
