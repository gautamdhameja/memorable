import CoreML
import Foundation

protocol CoreMLModelPredicting: AnyObject, Sendable {
    func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider
    func predictions(
        from inputBatch: MLBatchProvider,
        options: MLPredictionOptions
    ) throws -> MLBatchProvider
}

extension MLModel: CoreMLModelPredicting {}

enum ModelResource: CaseIterable, Equatable {
    case imageEncoder
    case textEncoder

    var resourceName: String {
        switch self {
        case .imageEncoder: return "SigLIP2_ImageEncoder"
        case .textEncoder: return "SigLIP2_TextEncoder"
        }
    }

    var fileExtension: String { "mlmodelc" }
}

enum ModelPackagingStrategy: String {
    case bundled
}

enum ModelResourceAvailability: Equatable {
    case available(URL)
    case unavailable(String)
}

enum ModelResourceError: LocalizedError, Equatable {
    case unavailable(ModelResource)

    var errorDescription: String? {
        switch self {
        case .unavailable(let resource):
            return "\(resource.resourceName) is unavailable. Reinstall the app or restore the bundled model resource."
        }
    }
}

protocol ModelResourceManaging: Sendable {
    var activeStrategy: ModelPackagingStrategy { get }
    func availability(for resource: ModelResource) -> ModelResourceAvailability
    func url(for resource: ModelResource) throws -> URL
}

final class ModelResourceManager: ModelResourceManaging, Sendable {
    static let shared = ModelResourceManager()

    let activeStrategy: ModelPackagingStrategy = .bundled
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func availability(for resource: ModelResource) -> ModelResourceAvailability {
        guard let url = bundle.url(forResource: resource.resourceName, withExtension: resource.fileExtension) else {
            return .unavailable("\(resource.resourceName).\(resource.fileExtension) is not present in the app bundle")
        }
        return .available(url)
    }

    func url(for resource: ModelResource) throws -> URL {
        switch availability(for: resource) {
        case .available(let url):
            return url
        case .unavailable:
            throw ModelResourceError.unavailable(resource)
        }
    }
}
