import SwiftUI
import Photos
import os

let logger = Logger(subsystem: "com.proferent.memorable", category: "app")

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

    var imageEncoder: ImageEncoder?
    var textEncoder: TextEncoder?
    var searchEngine: SearchEngine?
    var indexingService: IndexingService?
    let captionService = PhotoCaptionService()

    func initialize() async {
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

            let imgEncoder = try ImageEncoder()
            #if DEBUG
            logger.info("[AppState] ImageEncoder loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - modelStart))s")
            let textStart = CFAbsoluteTimeGetCurrent()
            #endif

            let txtEncoder = try TextEncoder()

            #if DEBUG
            logger.info("[AppState] TextEncoder loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - textStart))s")
            #endif

            let search = SearchEngine(textEncoder: txtEncoder)
            imageEncoder = imgEncoder
            textEncoder = txtEncoder
            searchEngine = search
            indexingService = IndexingService(imageEncoder: imgEncoder, searchEngine: search)
            captionService.prepare(textEncoder: txtEncoder)
            isModelLoaded = true

            #if DEBUG
            let indexStart = CFAbsoluteTimeGetCurrent()
            #endif

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
