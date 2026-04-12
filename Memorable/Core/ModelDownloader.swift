import Foundation

class ModelDownloader: ObservableObject {
    @Published var isDownloaded = false
    @Published var downloadProgress: Double = 0
    @Published var errorMessage: String?

    private var resourceRequest: NSBundleResourceRequest?
    private var observation: NSKeyValueObservation?

    func checkAndDownloadModels() {
        // Fast path: if models are already in the app bundle (non-ODR build
        // or previously cached ODR resources still present), skip the request.
        if Bundle.main.url(forResource: "MobileCLIP2_S4_ImageEncoder", withExtension: "mlmodelc") != nil {
            isDownloaded = true
            return
        }

        // Request via On-Demand Resources. In debug builds Xcode serves the
        // asset pack from a local server; in production App Store Connect
        // hosts it. beginAccessingResources is instant when the resources
        // are already cached, so there is no visible delay on repeat launches.
        let request = NSBundleResourceRequest(tags: ["ml-models"])
        self.resourceRequest = request
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent

        observation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        request.beginAccessingResources { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.errorMessage = "Failed to download AI models: \(error.localizedDescription)"
                } else {
                    self?.isDownloaded = true
                }
            }
        }
    }
}
