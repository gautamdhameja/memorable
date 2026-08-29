import Foundation
import Accelerate

struct DuplicatePair: Identifiable, Sendable {
    let id: String
    let photo1Id: String
    let photo1LocalId: String
    let photo2Id: String
    let photo2LocalId: String
    let similarity: Float
}

class DuplicateFinder {
    /// Keeps duplicate review bounded even when every scanned image is nearly
    /// identical. This is intentionally independent of library size.
    static let maximumRetainedPairs = 2_000

    /// Pairwise duplicate detection is quadratic. Stop after a deterministic
    /// amount of work so a large or adversarial library cannot monopolize CPU,
    /// GPU, or battery indefinitely.
    static let maximumComparisons = 5_000_000

    static func findDuplicates(
        ids: [String],
        localIdentifiers: [String],
        embeddings: [Float16],
        embeddingDim: Int = EmbeddingConfig.dimensions,
        threshold: Float = SearchConfig.duplicateThreshold
    ) -> [DuplicatePair] {
        let maxPhotos = min(ids.count, IndexingConfig.maxDuplicateScanPhotos)

        // Invariant: the flat embeddings buffer must hold at least one row per
        // photo we intend to scan. Bail out instead of letting pointer
        // arithmetic walk off the end if a caller ever passes inconsistent data.
        guard embeddings.count >= maxPhotos * embeddingDim,
              localIdentifiers.count >= ids.count else {
            logger.error("DuplicateFinder: array size mismatch (ids=\(ids.count), localIds=\(localIdentifiers.count), embeddings=\(embeddings.count), expected >=\(maxPhotos * embeddingDim))")
            return []
        }

        #if !targetEnvironment(simulator)
        // GPU-accelerated path
        if let gpu = GPUSimilaritySearch(embeddingDim: embeddingDim) {
            gpu.buildIndex(embeddings: embeddings, count: maxPhotos)
            let pairs = gpu.findDuplicates(
                embeddings: embeddings,
                count: maxPhotos,
                threshold: threshold,
                maximumResults: maximumRetainedPairs,
                maximumComparisons: maximumComparisons
            )
            return pairs.map { candidate in
                DuplicatePair(
                    id: "\(ids[candidate.firstIndex])::\(ids[candidate.secondIndex])",
                    photo1Id: ids[candidate.firstIndex],
                    photo1LocalId: localIdentifiers[candidate.firstIndex],
                    photo2Id: ids[candidate.secondIndex],
                    photo2LocalId: localIdentifiers[candidate.secondIndex],
                    similarity: candidate.score
                )
            }
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
        var candidates = DuplicateCandidateHeap(capacity: maximumRetainedPairs)
        var rowI = [Float](repeating: 0, count: embeddingDim)
        var rowJ = [Float](repeating: 0, count: embeddingDim)
        var comparisons = 0

        for i in 0..<maxPhotos {
            guard !Task.isCancelled, comparisons < maximumComparisons else { break }
            let offsetI = i * embeddingDim
            for d in 0..<embeddingDim { rowI[d] = Float(embeddings[offsetI + d]) }

            for j in (i + 1)..<maxPhotos {
                guard comparisons < maximumComparisons else { break }
                comparisons += 1
                if comparisons.isMultiple(of: 1_024), Task.isCancelled { break }

                let offsetJ = j * embeddingDim
                for d in 0..<embeddingDim { rowJ[d] = Float(embeddings[offsetJ + d]) }

                var dot: Float = 0
                vDSP_dotpr(rowI, 1, rowJ, 1, &dot, vDSP_Length(embeddingDim))

                if dot >= threshold {
                    candidates.insert(DuplicateCandidate(firstIndex: i, secondIndex: j, score: dot))
                }
            }
        }

        return candidates.sortedBestFirst().map { candidate in
            DuplicatePair(
                id: "\(ids[candidate.firstIndex])::\(ids[candidate.secondIndex])",
                photo1Id: ids[candidate.firstIndex],
                photo1LocalId: localIdentifiers[candidate.firstIndex],
                photo2Id: ids[candidate.secondIndex],
                photo2LocalId: localIdentifiers[candidate.secondIndex],
                similarity: candidate.score
            )
        }
    }
}

struct DuplicateCandidate: Sendable {
    let firstIndex: Int
    let secondIndex: Int
    let score: Float

    static func isBetter(_ lhs: Self, than rhs: Self) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.firstIndex != rhs.firstIndex { return lhs.firstIndex < rhs.firstIndex }
        return lhs.secondIndex < rhs.secondIndex
    }
}

/// A min-heap whose root is the least useful retained candidate.
struct DuplicateCandidateHeap {
    private(set) var storage: [DuplicateCandidate] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    mutating func insert(_ candidate: DuplicateCandidate) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(candidate)
            siftUp(from: storage.count - 1)
        } else if let worst = storage.first, DuplicateCandidate.isBetter(candidate, than: worst) {
            storage[0] = candidate
            siftDown(from: 0)
        }
    }

    func sortedBestFirst() -> [DuplicateCandidate] {
        storage.sorted { DuplicateCandidate.isBetter($0, than: $1) }
    }

    private func isWorse(_ lhs: DuplicateCandidate, than rhs: DuplicateCandidate) -> Bool {
        DuplicateCandidate.isBetter(rhs, than: lhs)
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(storage[child], than: storage[parent]) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { return }
            let right = left + 1
            var worseChild = left
            if right < storage.count, isWorse(storage[right], than: storage[left]) {
                worseChild = right
            }
            guard isWorse(storage[worseChild], than: storage[parent]) else { return }
            storage.swapAt(parent, worseChild)
            parent = worseChild
        }
    }
}
