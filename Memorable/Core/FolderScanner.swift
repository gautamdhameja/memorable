import Foundation
import UIKit
import Darwin
import CryptoKit

struct FolderIndexingImage {
    let image: UIImage
    let date: Date?
    let latitude: Double?
    let longitude: Double?
    let width: Int
    let height: Int
}

enum FolderBookmarkStore {
    struct DeletionToken: Equatable {
        let liveURL: URL
        let pendingURL: URL
    }

    private static let pendingDeletionSuffix = ".deletion-pending"

    private static func bookmarkDirectoryURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = appSupport
            .appendingPathComponent("Memorable", isDirectory: true)
            .appendingPathComponent("FolderBookmarks", isDirectory: true)
        try LocalOnlyStorage.prepareDirectory(at: root)
        return root
    }

    static func bookmarkURL(for sourceId: String) throws -> URL {
        let root = try bookmarkDirectoryURL()
        let digest = SHA256.hash(data: Data(sourceId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent("\(digest).bookmark", isDirectory: false)
    }

    static func data(for sourceId: String) -> Data? {
        do {
            return try loadData(for: sourceId)
        } catch {
            logger.error("[FolderBookmarkStore] Read or migration failed: \(error.safeDiagnosticCode)")
            return nil
        }
    }

    static func loadData(for sourceId: String) throws -> Data? {
        try migrateLegacyDataIfNeeded(for: sourceId)
        let url = try bookmarkURL(for: sourceId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func migrateLegacyDataIfNeeded(for sourceId: String) throws {
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceId)
        let url = try bookmarkURL(for: sourceId)
        if FileManager.default.fileExists(atPath: url.path) {
            // Remove a legacy duplicate only after confirming that the local,
            // backup-excluded replacement remains readable.
            _ = try Data(contentsOf: url, options: .mappedIfSafe)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return
        }
        guard let legacyData = UserDefaults.standard.data(forKey: legacyKey) else {
            return
        }
        try set(legacyData, for: sourceId)
    }

    static func set(_ data: Data, for sourceId: String) throws {
        let url = try bookmarkURL(for: sourceId)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try LocalOnlyStorage.excludeFromBackup(url)
        UserDefaults.standard.removeObject(
            forKey: AppKeys.folderBookmark(sourceId: sourceId)
        )
    }

    static func stageDeletion(for sourceId: String) throws -> DeletionToken? {
        try migrateLegacyDataIfNeeded(for: sourceId)
        let liveURL = try bookmarkURL(for: sourceId)
        let pendingURL = URL(fileURLWithPath: liveURL.path + pendingDeletionSuffix)
        if FileManager.default.fileExists(atPath: pendingURL.path) {
            return DeletionToken(liveURL: liveURL, pendingURL: pendingURL)
        }
        guard FileManager.default.fileExists(atPath: liveURL.path) else { return nil }
        try FileManager.default.moveItem(at: liveURL, to: pendingURL)
        return DeletionToken(liveURL: liveURL, pendingURL: pendingURL)
    }

    static func restoreStagedDeletion(_ token: DeletionToken?) throws {
        guard let token,
              FileManager.default.fileExists(atPath: token.pendingURL.path) else { return }
        if FileManager.default.fileExists(atPath: token.liveURL.path) {
            try FileManager.default.removeItem(at: token.pendingURL)
        } else {
            try FileManager.default.moveItem(at: token.pendingURL, to: token.liveURL)
        }
    }

    static func finalizeStagedDeletion(_ token: DeletionToken?) throws {
        guard let token else { return }
        do {
            try FileManager.default.removeItem(at: token.pendingURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The desired state is already present.
        }
    }

    static func recoverStagedDeletionIfNeeded(for sourceId: String) throws {
        let liveURL = try bookmarkURL(for: sourceId)
        let pendingURL = URL(fileURLWithPath: liveURL.path + pendingDeletionSuffix)
        try restoreStagedDeletion(DeletionToken(liveURL: liveURL, pendingURL: pendingURL))
    }

    static func reconcileStagedDeletions(liveSourceIDs: [String]) -> [String] {
        var failedSourceIDs: [String] = []
        var protectedPendingPaths: Set<String> = []
        for sourceID in liveSourceIDs {
            do {
                let liveURL = try bookmarkURL(for: sourceID)
                protectedPendingPaths.insert(liveURL.path + pendingDeletionSuffix)
                try recoverStagedDeletionIfNeeded(for: sourceID)
            } catch {
                failedSourceIDs.append(sourceID)
                logger.error("[FolderBookmarkStore] Failed to recover a staged bookmark deletion: \(error.safeDiagnosticCode)")
            }
        }
        do {
            try cleanupCommittedStagedDeletions(
                in: bookmarkDirectoryURL(),
                protectedPendingPaths: protectedPendingPaths
            )
        } catch {
            logger.error("[FolderBookmarkStore] Failed to clean committed staged bookmark deletions: \(error.safeDiagnosticCode)")
        }
        return failedSourceIDs
    }

    static func cleanupCommittedStagedDeletions(
        in directory: URL,
        protectedPendingPaths: Set<String>,
        fileManager: FileManager = .default
    ) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files where
            file.path.hasSuffix(pendingDeletionSuffix)
                && !protectedPendingPaths.contains(file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    static func remove(
        for sourceId: String,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        let url = try bookmarkURL(for: sourceId)
        do {
            try removeItem(url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The desired state is already present.
        }
        UserDefaults.standard.removeObject(
            forKey: AppKeys.folderBookmark(sourceId: sourceId)
        )
    }
}

class FolderScanner {
    struct ScanResult: Sendable, Equatable {
        let imageURLs: [URL]
        let isComplete: Bool
    }

    struct ValidatedImageSnapshot: Sendable {
        let data: Data
        let typeIdentifier: String
    }

    /// Folder sources are user-selected, but their trees can still be
    /// unexpectedly large. Match the app's documented large-library ceiling
    /// instead of buffering an unbounded number of URLs.
    static let maximumScannedImages = IndexingConfig.largeLibraryThreshold
    /// Bound total directory entries, including unsupported files, so a
    /// user-selected tree cannot force an effectively unbounded traversal.
    static let maximumVisitedEntries = 100_000
    /// Reject folder-source files larger than 32 MiB before ImageIO parses
    /// them. The decoded-pixel cap protects output surfaces; this independent
    /// bound protects compressed containers and metadata parsing.
    static let maximumImageFileBytes = 32 * 1_024 * 1_024
    /// Bounds decoded display images independently of caller-provided sizes.
    /// A 2048-pixel edge keeps zoom useful without creating oversized
    /// bitmaps on high-density displays.
    static let maximumDecodedPixelDimension: CGFloat = 2_048
    // `.withSecurityScope` is unavailable on iOS. Persist the document-picker
    // bookmark and pair every access with start/stopAccessingSecurityScopedResource.
    private static let bookmarkOptions: URL.BookmarkCreationOptions = .minimalBookmark
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    // Resolve a saved bookmark back to a security-scoped URL
    static func resolveBookmark(forSourceId sourceId: String) -> URL? {
        guard let data = FolderBookmarkStore.data(for: sourceId) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            do {
                let fresh = try url.bookmarkData(
                    options: bookmarkOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try FolderBookmarkStore.set(fresh, for: sourceId)
            } catch {
                logger.error("[FolderScanner] Failed to refresh bookmark: \(error.safeDiagnosticCode)")
            }
        }
        return url
    }

    static let supportedExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "bmp"])
    private static let supportedImageTypeIdentifiers = Set([
        "public.jpeg",
        "public.png",
        "public.heic",
        "public.heif",
        "org.webmproject.webp",
        "public.tiff",
        "com.microsoft.bmp",
    ])

    static func loadImageFromBookmarkedSource(
        filePath: String,
        sourceId: String,
        targetSize: CGSize
    ) -> UIImage? {
        let imageURL = URL(fileURLWithPath: filePath)
        guard sourceId != PhotoSourceType.photokit.rawValue else {
            logger.error("[FolderScanner] Refusing a folder path on a PhotoKit source")
            return nil
        }

        guard let folderURL = resolveBookmark(forSourceId: sourceId) else {
            logger.error("[FolderScanner] Could not resolve a folder bookmark")
            return nil
        }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        guard hasAccess else {
            logger.error("[FolderScanner] Could not access a folder bookmark")
            return nil
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        guard let image = loadImage(
            from: imageURL,
            within: folderURL,
            targetSize: targetSize
        ) else {
            logger.error("[FolderScanner] Refusing an invalid bookmarked image path")
            return nil
        }
        return image
    }

    static func validatedImageSnapshotFromBookmarkedSource(
        filePath: String,
        sourceId: String
    ) -> ValidatedImageSnapshot? {
        let imageURL = URL(fileURLWithPath: filePath)
        guard sourceId != PhotoSourceType.photokit.rawValue,
              let folderURL = resolveBookmark(forSourceId: sourceId) else {
            return nil
        }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        guard hasAccess else { return nil }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        return validatedImageSnapshot(imageURL, within: folderURL)
    }

    static func validatedImageSnapshot(
        _ imageURL: URL,
        within folderURL: URL
    ) -> ValidatedImageSnapshot? {
        withValidatedImageFileDescriptor(imageURL, within: folderURL) { descriptor in
            guard let snapshot = immutableSnapshot(for: descriptor),
                  let source = CGImageSourceCreateWithData(snapshot as CFData, nil),
                  let detectedType = CGImageSourceGetType(source) as String?,
                  supportedImageTypeIdentifiers.contains(detectedType) else {
                return nil
            }
            return ValidatedImageSnapshot(
                data: snapshot,
                typeIdentifier: detectedType
            )
        } ?? nil
    }

    /// Checks that a stored folder result is still reachable through its
    /// security-scoped bookmark without decoding or loading the image.
    static func canAccessBookmarkedImage(filePath: String, sourceId: String) -> Bool {
        guard sourceId != PhotoSourceType.photokit.rawValue,
              let folderURL = resolveBookmark(forSourceId: sourceId) else {
            return false
        }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        guard hasAccess else { return false }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        return isValidImageFile(URL(fileURLWithPath: filePath), within: folderURL)
    }

    /// Validates several results under one security-scoped folder access.
    static func accessibleBookmarkedImagePaths(
        _ filePaths: [String],
        sourceId: String
    ) -> Set<String> {
        guard sourceId != PhotoSourceType.photokit.rawValue,
              let folderURL = resolveBookmark(forSourceId: sourceId) else {
            return []
        }
        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        guard hasAccess else { return [] }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        return Set(filePaths.filter {
            !Task.isCancelled
                && isValidImageFile(URL(fileURLWithPath: $0), within: folderURL)
        })
    }

    static func isValidImageFile(_ imageURL: URL, within folderURL: URL) -> Bool {
        withValidatedImageFileDescriptor(imageURL, within: folderURL) { _ in true } == true
    }

    /// Opens a regular image by walking downward from the selected folder's
    /// descriptor. Every component uses `O_NOFOLLOW`, and the descriptor stays
    /// open for the caller's complete read. Validation therefore applies to
    /// the same file object that is decoded even if its pathname is replaced.
    @discardableResult
    static func withValidatedImageFileDescriptor<T>(
        _ imageURL: URL,
        within folderURL: URL,
        _ operation: (Int32) throws -> T
    ) rethrows -> T? {
        guard let components = validatedRelativeComponents(
            for: imageURL,
            within: folderURL
        ) else {
            return nil
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var directoryDescriptor = folderURL.standardizedFileURL.path.withCString {
            open($0, directoryFlags)
        }
        guard directoryDescriptor >= 0 else { return nil }
        defer { close(directoryDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, directoryFlags)
            }
            guard nextDescriptor >= 0 else { return nil }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        guard let fileName = components.last else { return nil }
        let fileDescriptor = fileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else { return nil }
        defer { close(fileDescriptor) }

        guard isSafeRegularImageFile(fileDescriptor) else { return nil }
        return try operation(fileDescriptor)
    }

    @discardableResult
    static func withValidatedImageSource<T>(
        _ imageURL: URL,
        within folderURL: URL,
        _ operation: (CGImageSource, Date?) throws -> T
    ) rethrows -> T? {
        try withValidatedImageFileDescriptor(imageURL, within: folderURL) { descriptor in
            guard let snapshot = immutableSnapshot(for: descriptor),
                  let source = CGImageSourceCreateWithData(snapshot as CFData, nil),
                  let detectedType = CGImageSourceGetType(source) as String?,
                  supportedImageTypeIdentifiers.contains(detectedType) else {
                return nil
            }
            return try operation(source, modificationDate(for: descriptor))
        } ?? nil
    }

    /// Uses the same no-symlink, source-bounded descriptor checks as decoding.
    static func fileModificationDate(_ imageURL: URL, within folderURL: URL) -> Date? {
        withValidatedImageFileDescriptor(imageURL, within: folderURL) {
            modificationDate(for: $0)
        } ?? nil
    }

    private static func validatedRelativeComponents(
        for imageURL: URL,
        within folderURL: URL
    ) -> [String]? {
        guard supportedExtensions.contains(imageURL.pathExtension.lowercased()) else {
            return nil
        }

        let folderPath = folderURL.standardizedFileURL.path
        let imagePath = imageURL.standardizedFileURL.path
        let prefix = folderPath == "/" ? "/" : folderPath + "/"
        guard imagePath.hasPrefix(prefix), imagePath.count > prefix.count else {
            return nil
        }

        let components = imagePath.dropFirst(prefix.count).split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

    private static func isSafeRegularImageFile(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maximumImageFileBytes),
              info.st_blocks >= 0,
              info.st_blocks <= Int64(maximumImageFileBytes / 512) else {
            return false
        }
        return true
    }

    private static func immutableSnapshot(for descriptor: Int32) -> Data? {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size > 0,
              info.st_size <= off_t(maximumImageFileBytes) else {
            return nil
        }
        let expectedCount = Int(info.st_size)
        var data = Data(count: expectedCount)
        let completed = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < expectedCount {
                guard !Task.isCancelled else { return false }
                let result = pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedCount - offset,
                    off_t(offset)
                )
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        return completed ? data : nil
    }

    private static func modificationDate(for descriptor: Int32) -> Date? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    static func localIdentifier(for imageURL: URL, within folderURL: URL, sourceId: String) -> String {
        let folderPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = imageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let relativePath: String
        if filePath.hasPrefix(folderPath + "/") {
            relativePath = String(filePath.dropFirst(folderPath.count + 1))
        } else {
            relativePath = imageURL.lastPathComponent
        }
        return "folder:\(sourceId):\(relativePath)"
    }

    // Scan a folder and report whether every entry was examined. Callers must
    // only remove stale database rows after a complete traversal.
    static func scanFolder(
        at url: URL,
        maximumImageCount: Int = maximumScannedImages,
        maximumVisitedEntryCount: Int = maximumVisitedEntries
    ) -> ScanResult {
        let limit = max(0, maximumImageCount)
        let visitLimit = max(0, maximumVisitedEntryCount)
        guard limit > 0, visitLimit > 0, !Task.isCancelled else {
            return ScanResult(imageURLs: [], isComplete: false)
        }
        var imageURLs: [URL] = []
        imageURLs.reserveCapacity(min(limit, 1_000))
        var visitedEntryCount = 0
        var isComplete = true

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                isComplete = false
                logger.error("[FolderScanner] Could not inspect part of a selected folder: \(error.safeDiagnosticCode)")
                return true
            }
        ) else {
            return ScanResult(imageURLs: [], isComplete: false)
        }

        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else {
                isComplete = false
                break
            }
            guard visitedEntryCount < visitLimit else {
                isComplete = false
                break
            }
            visitedEntryCount += 1
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                logger.error("[FolderScanner] Could not read selected-folder attributes: \(error.safeDiagnosticCode)")
                isComplete = false
                continue
            }
            // Skip symlinks and special files before retaining a candidate.
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if values.isRegularFile == true, supportedExtensions.contains(ext) {
                guard imageURLs.count < limit else {
                    isComplete = false
                    break
                }
                imageURLs.append(fileURL)
            }
        }

        return ScanResult(
            imageURLs: imageURLs.sorted { $0.lastPathComponent < $1.lastPathComponent },
            isComplete: isComplete
        )
    }

    // Load a UIImage from a file URL at the target size for embedding
    static func loadImage(from url: URL, targetSize: CGSize = CGSize(width: 224, height: 224)) -> UIImage? {
        guard !Task.isCancelled,
              targetSize.width.isFinite,
              targetSize.height.isFinite,
              targetSize.width > 0,
              targetSize.height > 0 else {
            return nil
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.error("[FolderScanner] Failed to open an image source")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let maximumPixelSize = min(
            max(targetSize.width, targetSize.height),
            maximumDecodedPixelDimension
        )
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            logger.error("[FolderScanner] Failed to decode an image")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        // ImageIO already produced a pixel-bounded, aspect-preserving image.
        // Do not pass this pixel size through UIGraphicsImageRenderer, whose
        // default screen scale would multiply the allocation a second time.
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Validates the file against the selected folder immediately before
    /// ImageIO opens it. Call this overload for folder-source indexing so a
    /// path replaced after enumeration cannot redirect the read elsewhere.
    static func loadImage(
        from url: URL,
        within folderURL: URL,
        targetSize: CGSize = CGSize(width: 224, height: 224)
    ) -> UIImage? {
        guard !Task.isCancelled,
              targetSize.width.isFinite,
              targetSize.height.isFinite,
              targetSize.width > 0,
              targetSize.height > 0 else {
            return nil
        }
        return withValidatedImageSource(url, within: folderURL) { imageSource, _ in
            decodeImage(from: imageSource, targetSize: targetSize)
        } ?? nil
    }

    /// Loads all base-indexing data from one immutable, validated file snapshot.
    static func loadIndexingImage(
        from url: URL,
        within folderURL: URL,
        targetSize: CGSize = CGSize(width: 224, height: 224)
    ) -> FolderIndexingImage? {
        guard !Task.isCancelled,
              targetSize.width.isFinite,
              targetSize.height.isFinite,
              targetSize.width > 0,
              targetSize.height > 0 else {
            return nil
        }
        return withValidatedImageSource(url, within: folderURL) { imageSource, modificationDate in
            guard let image = decodeImage(from: imageSource, targetSize: targetSize),
                  !Task.isCancelled,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    0,
                    nil
                  ) as? [CFString: Any] else {
                return nil
            }
            let metadata = extractMetadata(
                from: properties,
                modificationDate: modificationDate
            )
            return FolderIndexingImage(
                image: image,
                date: metadata.date,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                width: properties[kCGImagePropertyPixelWidth] as? Int ?? Int(image.size.width),
                height: properties[kCGImagePropertyPixelHeight] as? Int ?? Int(image.size.height)
            )
        } ?? nil
    }

    // Load a thumbnail from a file URL
    static func loadThumbnail(from url: URL, targetSize: CGSize = CGSize(width: 400, height: 400)) -> UIImage? {
        guard !Task.isCancelled,
              targetSize.width.isFinite,
              targetSize.height.isFinite,
              targetSize.width > 0,
              targetSize.height > 0 else {
            return nil
        }
        let maximumPixelSize = min(
            max(targetSize.width, targetSize.height),
            maximumDecodedPixelDimension
        )
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        return UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
    }

    // Extract basic EXIF data from an image file
    static func extractMetadata(from url: URL) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard !Task.isCancelled,
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil)
        }
        guard !Task.isCancelled else { return (nil, nil, nil) }

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

        if !LocationCoordinatePolicy.isValidOrAbsent(
            latitude: latitude,
            longitude: longitude
        ) {
            latitude = nil
            longitude = nil
        }

        return (date, latitude, longitude)
    }

    /// Validates containment again before reading metadata because the file
    /// can change between folder enumeration and indexing.
    static func extractMetadata(
        from url: URL,
        within folderURL: URL
    ) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard !Task.isCancelled else { return (nil, nil, nil) }
        return withValidatedImageSource(url, within: folderURL) { imageSource, modificationDate in
            extractMetadata(from: imageSource, modificationDate: modificationDate)
        } ?? (nil, nil, nil)
    }

    /// Returns source pixel dimensions after a fresh containment check.
    static func imageDimensions(
        from url: URL,
        within folderURL: URL
    ) -> (width: Int, height: Int) {
        guard !Task.isCancelled else { return (0, 0) }
        return withValidatedImageSource(url, within: folderURL) { imageSource, _ in
            guard !Task.isCancelled,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    0,
                    nil
                  ) as? [CFString: Any] else {
                return (0, 0)
            }
            return (
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            )
        } ?? (0, 0)
    }

    private static func decodeImage(
        from imageSource: CGImageSource,
        targetSize: CGSize
    ) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let maximumPixelSize = min(
            max(targetSize.width, targetSize.height),
            maximumDecodedPixelDimension
        )
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ), !Task.isCancelled else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func extractMetadata(
        from imageSource: CGImageSource,
        modificationDate: Date?
    ) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard !Task.isCancelled,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                imageSource,
                0,
                nil
              ) as? [CFString: Any] else {
            return (nil, nil, nil)
        }

        return extractMetadata(from: properties, modificationDate: modificationDate)
    }

    private static func extractMetadata(
        from properties: [CFString: Any],
        modificationDate: Date?
    ) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard !Task.isCancelled else { return (nil, nil, nil) }

        var date: Date?
        var latitude: Double?
        var longitude: Double?
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = exifDateFormatter.date(from: dateString)
        }
        date = date ?? modificationDate

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            latitude = gps[kCGImagePropertyGPSLatitude] as? Double
            longitude = gps[kCGImagePropertyGPSLongitude] as? Double
            if let reference = gps[kCGImagePropertyGPSLatitudeRef] as? String,
               reference == "S" {
                latitude = latitude.map { -$0 }
            }
            if let reference = gps[kCGImagePropertyGPSLongitudeRef] as? String,
               reference == "W" {
                longitude = longitude.map { -$0 }
            }
        }

        if !LocationCoordinatePolicy.isValidOrAbsent(
            latitude: latitude,
            longitude: longitude
        ) {
            latitude = nil
            longitude = nil
        }
        return (date, latitude, longitude)
    }
}
