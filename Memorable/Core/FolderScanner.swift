import Foundation
import UIKit

class FolderScanner {

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    // Resolve a saved bookmark back to a security-scoped URL
    static func resolveBookmark(forSourceId sourceId: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceId)) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale {
            // Re-save refreshed bookmark
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: AppKeys.folderBookmark(sourceId: sourceId))
            }
        }
        return url
    }

    static let supportedExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "bmp"])

    static func loadImageFromBookmarkedSource(
        filePath: String,
        sourceId: String,
        targetSize: CGSize
    ) -> UIImage? {
        let imageURL = URL(fileURLWithPath: filePath)
        guard sourceId != PhotoSourceType.photokit.rawValue else {
            logger.error("[FolderScanner] Refusing folder image path on PhotoKit source: \(imageURL.lastPathComponent)")
            return nil
        }

        guard let folderURL = resolveBookmark(forSourceId: sourceId) else {
            logger.error("[FolderScanner] Could not resolve bookmark for source: \(sourceId)")
            return nil
        }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        guard hasAccess else {
            logger.error("[FolderScanner] Could not access bookmark for source: \(sourceId)")
            return nil
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        guard isValidImageFile(imageURL, within: folderURL) else {
            logger.error("[FolderScanner] Refusing image path outside bookmarked folder: \(imageURL.lastPathComponent)")
            return nil
        }

        return loadImage(from: imageURL, targetSize: targetSize)
    }

    static func isValidImageFile(_ imageURL: URL, within folderURL: URL) -> Bool {
        let ext = imageURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return false }

        do {
            let values = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return false
            }
        } catch {
            logger.error("[FolderScanner] Failed to validate image file: \(error.localizedDescription)")
            return false
        }

        let folderPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = imageURL.standardizedFileURL.resolvingSymlinksInPath().path
        return filePath.hasPrefix(folderPath + "/")
    }

    // Scan a folder and return all image file URLs
    static func scanFolder(at url: URL) -> [URL] {
        var imageURLs: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            // Skip symlinks to prevent traversal outside the selected folder
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                imageURLs.append(fileURL)
            }
        }

        return imageURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Load a UIImage from a file URL at the target size for embedding
    static func loadImage(from url: URL, targetSize: CGSize = CGSize(width: 224, height: 224)) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            #if DEBUG
            logger.error("[FolderScanner] Failed to open image source: \(url.lastPathComponent)")
            #endif
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            #if DEBUG
            logger.error("[FolderScanner] Failed to decode image: \(url.lastPathComponent)")
            #endif
            return nil
        }

        let image = UIImage(cgImage: cgImage)

        // Resize to target size
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    // Load a thumbnail from a file URL
    static func loadThumbnail(from url: URL, targetSize: CGSize = CGSize(width: 400, height: 400)) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: thumbnail)
    }

    // Extract basic EXIF data from an image file
    static func extractMetadata(from url: URL) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil)
        }

        var date: Date?
        var latitude: Double?
        var longitude: Double?

        // Extract date from EXIF
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = exifDateFormatter.date(from: dateString)
        }

        // Fall back to file modification date
        if date == nil {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            date = attrs?[.modificationDate] as? Date
        }

        // Extract GPS
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            latitude = gps[kCGImagePropertyGPSLatitude] as? Double
            longitude = gps[kCGImagePropertyGPSLongitude] as? Double

            // Handle N/S and E/W references
            if let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String, latRef == "S" {
                latitude = latitude.map { -$0 }
            }
            if let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String, lonRef == "W" {
                longitude = longitude.map { -$0 }
            }
        }

        return (date, latitude, longitude)
    }
}
