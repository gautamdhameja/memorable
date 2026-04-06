import SwiftUI
import QuickLook
import Photos

struct FullScreenPhotoViewer: View {
    let localIdentifier: String
    let creationDate: Date?

    @State private var fileURL: URL?
    @State private var cachedFileURL: URL?
    @State private var isLoading = true
    @State private var loadFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Unable to load photo")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                    Button("Dismiss") { dismiss() }
                        .foregroundStyle(Celestial.Colors.primaryDim)
                }
            }
        }
        .quickLookPreview($fileURL)
        .task {
            guard let asset = PhotoLibrary.getAsset(by: localIdentifier) else {
                loadFailed = true
                isLoading = false
                return
            }
            let url = await PhotoLibrary.getQuickLookURL(for: asset)
            if let url {
                cachedFileURL = url
                fileURL = url
            } else {
                loadFailed = true
            }
            isLoading = false
        }
        .onChange(of: fileURL) {
            if fileURL == nil && !isLoading && !loadFailed {
                if let cachedURL = cachedFileURL {
                    PhotoLibrary.cleanupQuickLookFile(at: cachedURL)
                }
                dismiss()
            }
        }
    }
}
