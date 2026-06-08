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
                    ZoomableAsyncImage(result: result, isActive: index == currentIndex, onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    })
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
                        .accessibilityLabel("Close")
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
                        .accessibilityLabel("Share")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    // Bottom info bar
                    if currentIndex < allResults.count {
                        let result = allResults[currentIndex]
                        HStack {
                            if let date = result.creationDate {
                                Text(date.formatted(date: .long, time: .shortened))
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.white)
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
            let item: Any
            if let url = await PhotoLibrary.getQuickLookURL(for: asset) {
                item = url
            } else if let image = await PhotoLibrary.loadImage(
                for: asset,
                targetSize: shareFallbackTargetSize()
            ) {
                item = image
            } else {
                return
            }

            await MainActor.run {
                let activityVC = UIActivityViewController(activityItems: [item], applicationActivities: nil)
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

    private func shareFallbackTargetSize() -> CGSize {
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        return CGSize(width: screen.width * scale * 2, height: screen.height * scale * 2)
    }
}
