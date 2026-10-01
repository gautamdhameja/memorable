import SwiftUI
import Photos

struct ZoomableAsyncImage: View {
    let result: SearchResult
    /// The page the user is looking at. Drives zoom reset and memory-pressure
    /// recovery.
    var isActive: Bool = true
    /// Whether this page keeps a decoded image. Neighbouring pages stay loaded
    /// so a swipe reveals the photo instead of a spinner.
    var shouldLoad: Bool = true
    var onSingleTap: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var imageLoadGeneration: UInt = 0
    @State private var imageLoadTask: Task<Void, Never>?
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
                    .onTapGesture(count: 1) {
                        onSingleTap?()
                    }
                    .onChange(of: scale) {
                        if !isZoomed {
                            offset = .zero
                        }
                    }
            } else {
                Self.unloadedContent(isLoading: isLoading, retry: retryImageLoad)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .task(id: shouldLoad) {
            imageLoadTask?.cancel()
            if shouldLoad {
                let task = Task { @MainActor in await loadImage() }
                imageLoadTask = task
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            } else {
                // Only pages outside the retention window release their image,
                // so paging back and forth does not decode the same photo again.
                imageLoadGeneration &+= 1
                image = nil
                isLoading = true
            }
        }
        .onChange(of: isActive) {
            // A page the user swiped away from must not return still zoomed in.
            if !isActive { resetZoom() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            handleMemoryPressure()
        }
        .onDisappear {
            imageLoadTask?.cancel()
            imageLoadTask = nil
            imageLoadGeneration &+= 1
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

    @ViewBuilder
    static func unloadedContent(isLoading: Bool, retry: @escaping () -> Void) -> some View {
        if isLoading {
            ProgressView().tint(.white)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                Text("Photo unavailable")
                    .font(Celestial.Typography.bodyEmphasized)
                Button("Try again", action: retry)
                    .celestialSecondaryButtonStyle()
            }
            .foregroundStyle(.white)
            .padding(24)
        }
    }

    private func retryImageLoad() {
        guard shouldLoad, !isLoading else { return }
        imageLoadTask?.cancel()
        isLoading = true
        imageLoadTask = Task { @MainActor in await loadImage() }
    }

    private func loadImage() async {
        guard !Task.isCancelled, shouldLoad else { return }
        imageLoadGeneration &+= 1
        let generation = imageLoadGeneration
        isLoading = true
        let targetSize = displayTargetSize()
        let loaded = await PhotoLibrary.loadPreviewImage(for: result, targetSize: targetSize)
        if ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: generation,
            currentGeneration: imageLoadGeneration,
            isCancelled: Task.isCancelled
        ) {
            image = loaded
            isLoading = false
        }
    }

    private func handleMemoryPressure() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        imageLoadGeneration &+= 1
        resetZoom()

        switch MemoryPressureImageRecoveryPolicy.decision(
            hasImage: image != nil,
            isActive: isActive,
            preserveVisibleImage: true
        ) {
        case .preserve:
            return
        case .release:
            MemoryPressureReleasePolicy.release(&image)
            isLoading = false
        case .releaseAndRetry:
            MemoryPressureReleasePolicy.release(&image)
            isLoading = true
            let task = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: MemoryPressureImageRecoveryPolicy.retryDelayNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, isActive else { return }
                await loadImage()
            }
            imageLoadTask = task
        }
    }

    private func displayTargetSize() -> CGSize {
        Self.displayTargetSize(
            screenSize: UIScreen.main.bounds.size,
            screenScale: UIScreen.main.scale
        )
    }

    static func displayTargetSize(
        screenSize: CGSize,
        screenScale: CGFloat,
        zoomHeadroom: CGFloat = 3,
        maximumPixelDimension: CGFloat = FolderScanner.maximumDecodedPixelDimension
    ) -> CGSize {
        guard screenSize.width > 0,
              screenSize.height > 0,
              screenScale.isFinite,
              screenScale > 0,
              zoomHeadroom.isFinite,
              zoomHeadroom > 0,
              maximumPixelDimension.isFinite,
              maximumPixelDimension > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let desired = CGSize(
            width: screenSize.width * screenScale * zoomHeadroom,
            height: screenSize.height * screenScale * zoomHeadroom
        )
        let reduction = min(1, maximumPixelDimension / max(desired.width, desired.height))
        return CGSize(width: desired.width * reduction, height: desired.height * reduction)
    }
}
