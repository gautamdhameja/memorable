import SwiftUI
import Photos

struct ZoomableAsyncImage: View {
    let result: SearchResult

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1.0
    @GestureState private var dragTranslation: CGSize = .zero

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { geo in
            if let image {
                let imgSize = fittedSize(image: image, in: geo.size)
                let clamped = clampedOffset(
                    raw: CGSize(width: offset.width + dragTranslation.width,
                                height: offset.height + dragTranslation.height),
                    imageSize: imgSize,
                    viewSize: geo.size
                )

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale * magnification)
                    .offset(clamped)
                    .gesture(pinchGesture)
                    .highPriorityGesture(isZoomed ? panGesture : nil)
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if isZoomed {
                                resetZoom()
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .onChange(of: scale) {
                        if !isZoomed {
                            offset = .zero
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .task {
            await loadImage()
        }
        .onDisappear {
            // Reset when swiped away so it's clean if user comes back
            resetZoom()
        }
    }

    private func resetZoom() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
    }

    // MARK: - Layout helpers

    private func fittedSize(image: UIImage, in viewSize: CGSize) -> CGSize {
        let imgAspect = image.size.width / image.size.height
        let viewAspect = viewSize.width / viewSize.height
        if imgAspect > viewAspect {
            return CGSize(width: viewSize.width, height: viewSize.width / imgAspect)
        } else {
            return CGSize(width: viewSize.height * imgAspect, height: viewSize.height)
        }
    }

    private func clampedOffset(raw: CGSize, imageSize: CGSize, viewSize: CGSize) -> CGSize {
        let currentScale = scale * magnification
        let scaledW = imageSize.width * currentScale
        let scaledH = imageSize.height * currentScale
        let maxX = max((scaledW - viewSize.width) / 2, 0)
        let maxY = max((scaledH - viewSize.height) / 2, 0)
        return CGSize(
            width: min(max(raw.width, -maxX), maxX),
            height: min(max(raw.height, -maxY), maxY)
        )
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let newScale = lastScale * value.magnification
                lastScale = max(1.0, min(newScale, 5.0))
                scale = lastScale
                if lastScale <= 1.0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        resetZoom()
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
            }
    }

    // MARK: - Loading

    private func loadImage() async {
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
