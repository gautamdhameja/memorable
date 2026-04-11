import SwiftUI
import Photos
import os

let logger = Logger(subsystem: "com.blockdeep.memorable", category: "app")

@main
struct MemorableApp: App {
    @StateObject private var appState = AppState()

    init() {
        PhotoLibrary.cleanupAllQuickLookFiles()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    #if DEBUG
                    logger.warning("[App] Memory warning received, dropping search index")
                    #endif
                    appState.searchEngine?.dropIndex()
                }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isModelLoaded = false
    @Published var errorMessage: String?
    @Published var loadingStatus: String = "Preparing your experience..."

    var imageEncoder: ImageEncoder?
    var textEncoder: TextEncoder?
    var searchEngine: SearchEngine?
    var indexingService: IndexingService?
    let captionService = PhotoCaptionService()
    private var isInitializing = false

    func initialize() async {
        guard !isInitializing && !isModelLoaded else { return }
        isInitializing = true
        #if DEBUG
        let initStart = CFAbsoluteTimeGetCurrent()
        logger.info("[AppState] initialize() started")
        #endif

        authorizationStatus = await PhotoLibrary.requestAuthorization()

        #if DEBUG
        logger.info("[AppState] Photo auth status: \(String(describing: self.authorizationStatus))")
        #endif

        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            if authorizationStatus == .denied || authorizationStatus == .restricted {
                return
            }
            errorMessage = "Photo library access is required to search your photos."
            return
        }

        do {
            #if DEBUG
            let modelStart = CFAbsoluteTimeGetCurrent()
            #endif

            loadingStatus = "Waking up the neural engine..."

            let imgEncoder = try await Task.detached {
                try ImageEncoder()
            }.value

            #if DEBUG
            logger.info("[AppState] ImageEncoder loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - modelStart))s")
            let textStart = CFAbsoluteTimeGetCurrent()
            #endif

            loadingStatus = "Understanding words and images..."

            let txtEncoder = try await Task.detached {
                try TextEncoder()
            }.value

            #if DEBUG
            logger.info("[AppState] TextEncoder loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - textStart))s")
            #endif

            loadingStatus = "Spinning up the search engine..."

            let search = await Task.detached {
                SearchEngine(textEncoder: txtEncoder)
            }.value

            imageEncoder = imgEncoder
            textEncoder = txtEncoder
            searchEngine = search
            indexingService = IndexingService(imageEncoder: imgEncoder, searchEngine: search)
            captionService.prepare(textEncoder: txtEncoder)
            isModelLoaded = true

            // Wire up refund handler: trim index to free tier limit
            ProManager.shared.onProRevoked = { [weak self] in
                do {
                    try AppDatabase.shared.trimToLimit(FreeTier.maxPhotos)
                    try search.loadIndex()
                    self?.indexingService?.indexVersion += 1
                } catch {
                    logger.error("Failed to trim index after refund: \(error.localizedDescription)")
                }
            }

            #if DEBUG
            let indexStart = CFAbsoluteTimeGetCurrent()
            #endif

            loadingStatus = "Getting your memories ready..."

            await indexingService?.checkAndLoadExistingIndex()

            #if DEBUG
            logger.info("[AppState] Index loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - indexStart))s")
            logger.info("[AppState] Total initialization: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - initStart))s")
            #endif
        } catch {
            logger.error("Model loading failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}
