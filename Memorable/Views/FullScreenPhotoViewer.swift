import SwiftUI
import QuickLook
import Photos

struct FullScreenPhotoViewer: View {
    let initialResult: SearchResult
    let allResults: [SearchResult]
    var searchEngine: SearchEngine? = nil

    @State private var currentIndex: Int = 0
    @State private var fileURL: URL?
    @State private var cachedFileURL: URL?
    @State private var isLoading = true
    @State private var loadFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(allResults.enumerated()), id: \.element.id) { index, result in
                    PhotoPage(result: result)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Top bar
            VStack {
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
                    // Share button
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

struct PhotoPage: View {
    let result: SearchResult
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task {
            if result.isVideo {
                if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                    image = await VideoFrameExtractor.thumbnail(
                        from: asset,
                        atPosition: result.bestFramePosition ?? 0.5,
                        targetSize: CGSize(width: 1024, height: 1024)
                    )
                }
            } else if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                image = await PhotoLibrary.loadImage(
                    for: asset,
                    targetSize: CGSize(width: 1024, height: 1024)
                )
            }
        }
    }
}

// UIScrollView-based zoomable image view
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // Double tap to zoom
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.zoomScale = 1.0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: scrollView.viewWithTag(100))
                let zoomRect = CGRect(
                    x: point.x - 100, y: point.y - 100,
                    width: 200, height: 200
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}
