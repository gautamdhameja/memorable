import Foundation
import Accelerate

struct DuplicatePair: Identifiable {
    let id: String
    let photo1Id: String
    let photo1LocalId: String
    let photo2Id: String
    let photo2LocalId: String
    let similarity: Float
}

class DuplicateFinder {

    static func findDuplicates(
        ids: [String],
        localIdentifiers: [String],
        embeddings: [Float16],
        embeddingDim: Int = EmbeddingConfig.dimensions,
        threshold: Float = 0.95
    ) -> [DuplicatePair] {
        let maxPhotos = min(ids.count, 10_000)

        #if !targetEnvironment(simulator)
        // GPU-accelerated path
        if let gpu = GPUSimilaritySearch() {
            gpu.buildIndex(embeddings: embeddings, count: maxPhotos)
            let pairs = gpu.findDuplicates(embeddings: embeddings, count: maxPhotos, threshold: threshold)
            return pairs.map { (i, j, score) in
                DuplicatePair(
                    id: UUID().uuidString,
                    photo1Id: ids[i],
                    photo1LocalId: localIdentifiers[i],
                    photo2Id: ids[j],
                    photo2LocalId: localIdentifiers[j],
                    similarity: score
                )
            }.sorted { $0.similarity > $1.similarity }
        }
        #endif

        // CPU fallback
        return findDuplicatesCPU(
            ids: ids, localIdentifiers: localIdentifiers,
            embeddings: embeddings, embeddingDim: embeddingDim,
            maxPhotos: maxPhotos, threshold: threshold
        )
    }

    private static func findDuplicatesCPU(
        ids: [String],
        localIdentifiers: [String],
        embeddings: [Float16],
        embeddingDim: Int,
        maxPhotos: Int,
        threshold: Float
    ) -> [DuplicatePair] {
        var duplicates: [DuplicatePair] = []
        var rowI = [Float](repeating: 0, count: embeddingDim)
        var rowJ = [Float](repeating: 0, count: embeddingDim)

        for i in 0..<maxPhotos {
            let offsetI = i * embeddingDim
            for d in 0..<embeddingDim { rowI[d] = Float(embeddings[offsetI + d]) }

            for j in (i + 1)..<maxPhotos {
                let offsetJ = j * embeddingDim
                for d in 0..<embeddingDim { rowJ[d] = Float(embeddings[offsetJ + d]) }

                var dot: Float = 0
                vDSP_dotpr(rowI, 1, rowJ, 1, &dot, vDSP_Length(embeddingDim))

                if dot >= threshold {
                    duplicates.append(DuplicatePair(
                        id: UUID().uuidString,
                        photo1Id: ids[i],
                        photo1LocalId: localIdentifiers[i],
                        photo2Id: ids[j],
                        photo2LocalId: localIdentifiers[j],
                        similarity: dot
                    ))
                }
            }
        }

        return duplicates.sorted { $0.similarity > $1.similarity }
    }
}
