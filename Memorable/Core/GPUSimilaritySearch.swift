import Foundation
import Metal
import MetalPerformanceShadersGraph
import os

protocol SimilaritySearching: AnyObject, Sendable {
    func buildIndex(embeddings: [Float16], count: Int)
    func search(queryEmbedding: [Float]) -> [Float]?
}

/// GPU-accelerated similarity search using MPSGraph matrix multiplication.
/// Replaces per-embedding CPU dot products with a single [N, 768] × [768, 1] GPU matmul.
final class GPUSimilaritySearch: SimilaritySearching {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let embeddingDim: Int

    private let indexState = OSAllocatedUnfairLock(uncheckedState: IndexState())

    private struct IndexState {
        var matrixBuffer: MTLBuffer?
        var cachedGraph: CachedGraph?
        var count = 0
    }

    private struct CachedGraph {
        let graph: MPSGraph
        let matrixPlaceholder: MPSGraphTensor
        let queryPlaceholder: MPSGraphTensor
        let resultTensor: MPSGraphTensor
    }

    init?(embeddingDim: Int = EmbeddingConfig.dimensions) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.embeddingDim = embeddingDim
    }

    /// Build the GPU index from Float16 embeddings (zero-copy path).
    func buildIndex(embeddings: [Float16], count: Int) {
        #if DEBUG
        let buildStart = CFAbsoluteTimeGetCurrent()
        #endif

        guard count > 0, embeddings.count >= count * embeddingDim else {
            indexState.withLockUnchecked { $0 = IndexState(count: count) }
            return
        }

        let byteCount = count * embeddingDim * MemoryLayout<Float16>.size
        let matrixBuffer = embeddings.withUnsafeBufferPointer { ptr -> MTLBuffer? in
            guard let baseAddress = ptr.baseAddress else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: byteCount, options: .storageModeShared)
        }

        // Build and cache the MPSGraph
        let graph = MPSGraph()
        let matrixShape: [NSNumber] = [NSNumber(value: count), NSNumber(value: embeddingDim)]
        let queryShape: [NSNumber] = [NSNumber(value: embeddingDim), NSNumber(value: 1)]

        let matrixPlaceholder = graph.placeholder(shape: matrixShape, dataType: .float16, name: "embeddings")
        let queryPlaceholder = graph.placeholder(shape: queryShape, dataType: .float16, name: "query")
        let resultTensor = graph.matrixMultiplication(
            primary: matrixPlaceholder,
            secondary: queryPlaceholder,
            name: "similarity"
        )

        let cachedGraph = CachedGraph(
            graph: graph,
            matrixPlaceholder: matrixPlaceholder,
            queryPlaceholder: queryPlaceholder,
            resultTensor: resultTensor
        )
        indexState.withLockUnchecked {
            $0 = IndexState(matrixBuffer: matrixBuffer, cachedGraph: cachedGraph, count: count)
        }

        #if DEBUG
        logger.info("[GPUSimilaritySearch] Index built: \(count) embeddings in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - buildStart))s")
        #endif
    }

    /// Compute similarity scores for a query embedding against all stored embeddings.
    /// Query should be L2-normalized Float array of embeddingDim length.
    /// Returns Float array of length N with similarity scores, or nil if GPU unavailable.
    func search(queryEmbedding: [Float]) -> [Float]? {
        let index = indexState.withLockUnchecked { $0 }
        guard index.count > 0,
              let cached = index.cachedGraph,
              let matBuf = index.matrixBuffer else {
            return nil
        }
        let count = index.count

        #if DEBUG
        let searchStart = CFAbsoluteTimeGetCurrent()
        #endif

        // Convert query to Float16
        var queryFloat16 = [Float16](repeating: 0, count: embeddingDim)
        for i in 0..<min(queryEmbedding.count, embeddingDim) {
            queryFloat16[i] = Float16(queryEmbedding[i])
        }

        // Matrix tensor data from pre-allocated buffer (no copy)
        let matrixShape: [NSNumber] = [NSNumber(value: count), NSNumber(value: embeddingDim)]
        let matrixTensorData = MPSGraphTensorData(matBuf, shape: matrixShape, dataType: .float16)

        // Query tensor data (tiny ~1.5KB buffer)
        let queryShape: [NSNumber] = [NSNumber(value: embeddingDim), NSNumber(value: 1)]
        let queryTensorData = queryFloat16.withUnsafeBufferPointer { ptr in
            MPSGraphTensorData(
                device: MPSGraphDevice(mtlDevice: device),
                data: Data(buffer: ptr),
                shape: queryShape,
                dataType: .float16
            )
        }

        // Execute GPU matmul
        let results = cached.graph.run(
            with: commandQueue,
            feeds: [cached.matrixPlaceholder: matrixTensorData,
                    cached.queryPlaceholder: queryTensorData],
            targetTensors: [cached.resultTensor],
            targetOperations: nil
        )

        guard let resultTensorData = results[cached.resultTensor] else { return nil }

        // Read results back as Float16, convert to Float32
        var resultFloat16 = [Float16](repeating: 0, count: count)
        resultTensorData.mpsndarray().readBytes(&resultFloat16, strideBytes: nil)

        var resultFloat32 = [Float](repeating: 0, count: count)
        for i in 0..<count {
            resultFloat32[i] = Float(resultFloat16[i])
        }

        #if DEBUG
        let n = count
        logger.info("[GPUSimilaritySearch] Search over \(n) embeddings in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - searchStart))s")
        #endif

        return resultFloat32
    }

    /// Compute pairwise similarity for a batch of query rows against all stored embeddings.
    /// Returns an array of (rowIndex, colIndex, score) triples above the threshold.
    /// Only the upper triangle (colIndex > rowIndex) is returned to avoid duplicates.
    func findDuplicates(
        embeddings: [Float16],
        count: Int,
        threshold: Float,
        batchSize: Int = 500,
        maximumResults: Int = DuplicateFinder.maximumRetainedPairs,
        maximumComparisons: Int = DuplicateFinder.maximumComparisons
    ) -> [DuplicateCandidate] {
        let index = indexState.withLockUnchecked { $0 }
        guard count > 0,
              let matBuf = index.matrixBuffer,
              index.cachedGraph != nil,
              index.count == count else {
            return []
        }

        var candidates = DuplicateCandidateHeap(capacity: maximumResults)
        let maxPhotos = min(count, 10_000)
        var comparisons = 0

        // Process in batches: [batchSize, D] × [D, N] = [batchSize, N]
        for batchStart in stride(from: 0, to: maxPhotos, by: batchSize) {
            guard !Task.isCancelled, comparisons < maximumComparisons else { break }
            let batchEnd = min(batchStart + batchSize, maxPhotos)
            let batchCount = batchEnd - batchStart

            // Build batch query matrix [batchCount, D] as transposed [D, batchCount]
            var batchFloat16 = [Float16](repeating: 0, count: batchCount * embeddingDim)
            for i in 0..<batchCount {
                let srcOffset = (batchStart + i) * embeddingDim
                let dstOffset = i * embeddingDim
                for d in 0..<embeddingDim {
                    batchFloat16[dstOffset + d] = embeddings[srcOffset + d]
                }
            }

            // Transpose to [D, batchCount] for matmul: [N, D] × [D, batchCount] = [N, batchCount]
            var transposed = [Float16](repeating: 0, count: embeddingDim * batchCount)
            for i in 0..<batchCount {
                for d in 0..<embeddingDim {
                    transposed[d * batchCount + i] = batchFloat16[i * embeddingDim + d]
                }
            }

            let batchGraph = MPSGraph()
            let matShape: [NSNumber] = [NSNumber(value: count), NSNumber(value: embeddingDim)]
            let qShape: [NSNumber] = [NSNumber(value: embeddingDim), NSNumber(value: batchCount)]

            let matPH = batchGraph.placeholder(shape: matShape, dataType: .float16, name: "mat")
            let qPH = batchGraph.placeholder(shape: qShape, dataType: .float16, name: "q")
            let result = batchGraph.matrixMultiplication(primary: matPH, secondary: qPH, name: "sim")

            let matTD = MPSGraphTensorData(matBuf, shape: matShape, dataType: .float16)
            let qTD = transposed.withUnsafeBufferPointer { ptr in
                MPSGraphTensorData(
                    device: MPSGraphDevice(mtlDevice: device),
                    data: Data(buffer: ptr),
                    shape: qShape,
                    dataType: .float16
                )
            }

            let output = batchGraph.run(
                with: commandQueue,
                feeds: [matPH: matTD, qPH: qTD],
                targetTensors: [result],
                targetOperations: nil
            )

            guard let resultData = output[result] else { continue }

            // Read [N, batchCount] result
            var resultFloat16 = [Float16](repeating: 0, count: count * batchCount)
            resultData.mpsndarray().readBytes(&resultFloat16, strideBytes: nil)

            // Extract upper-triangle pairs above threshold
            let thresholdF16 = Float16(threshold)
            let resultCount = resultFloat16.count
            for col in 0..<batchCount {
                guard !Task.isCancelled, comparisons < maximumComparisons else { break }
                let globalCol = batchStart + col
                for row in (globalCol + 1)..<maxPhotos {
                    guard comparisons < maximumComparisons else { break }
                    comparisons += 1
                    if comparisons.isMultiple(of: 1_024), Task.isCancelled { break }
                    let index = row * batchCount + col
                    guard index < resultCount else { continue }
                    let score = resultFloat16[index]
                    if score >= thresholdF16 {
                        candidates.insert(DuplicateCandidate(
                            firstIndex: globalCol,
                            secondIndex: row,
                            score: Float(score)
                        ))
                    }
                }
            }
        }

        return candidates.sortedBestFirst()
    }
}
