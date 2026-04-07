import Photos
import UIKit

class PhotoLibrary {

    // Request authorization to access the photo library
    static func requestAuthorization() async -> PHAuthorizationStatus {
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // Get a UIImage from a PHAsset at a specific size for embedding
    static func loadImage(for asset: PHAsset, targetSize: CGSize = CGSize(width: 224, height: 224)) async -> UIImage? {
        await withTimeout(seconds: TimeoutConfig.imageLoad) { completion in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false
            options.resizeMode = .exact

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    completion(image)
                } else if image == nil {
                    completion(nil)
                }
            }
        }
    }

    // Get a thumbnail for display in search results — preserves original aspect ratio
    static func loadThumbnail(for asset: PHAsset, maxDimension: CGFloat = 400) async -> UIImage? {
        // Compute target size that preserves the asset's aspect ratio
        let assetWidth = CGFloat(asset.pixelWidth)
        let assetHeight = CGFloat(asset.pixelHeight)
        let targetSize: CGSize
        if assetWidth > assetHeight {
            let scale = maxDimension / assetWidth
            targetSize = CGSize(width: maxDimension, height: assetHeight * scale)
        } else {
            let scale = maxDimension / assetHeight
            targetSize = CGSize(width: assetWidth * scale, height: maxDimension)
        }

        return await withTimeout(seconds: TimeoutConfig.imageLoad) { completion in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false
            options.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    completion(image)
                }
            }
        }
    }

    static func fetchAllMedia() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                         PHAssetMediaType.image.rawValue,
                                         PHAssetMediaType.video.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    static func getAsset(by localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }

    // MARK: - Quick Look Support

    private static var quickLookCacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("QuickLookPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func getQuickLookURL(for asset: PHAsset) async -> URL? {
        if asset.mediaType == .video {
            return await withTimeout(seconds: TimeoutConfig.videoLoad) { completion in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat

                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    completion((avAsset as? AVURLAsset)?.url)
                }
            }
        } else {
            return await withTimeout(seconds: TimeoutConfig.videoLoad) { completion in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat

                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                    guard let data else {
                        completion(nil)
                        return
                    }

                    let ext: String
                    if let uti, uti.hasPrefix("public.heic") || uti.hasPrefix("public.heif") {
                        ext = "heic"
                    } else if let uti, uti.contains("png") {
                        ext = "png"
                    } else {
                        ext = "jpg"
                    }

                    let fileURL = quickLookCacheDir
                        .appendingPathComponent(asset.localIdentifier.replacingOccurrences(of: "/", with: "_"))
                        .appendingPathExtension(ext)

                    do {
                        try data.write(to: fileURL, options: .atomic)
                        completion(fileURL)
                    } catch {
                        completion(nil)
                    }
                }
            }
        }
    }

    static func cleanupQuickLookFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupAllQuickLookFiles() {
        let dir = quickLookCacheDir
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
