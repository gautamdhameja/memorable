import Foundation

struct SearchIndexSnapshot: Sendable {
    var photos = MediaIndex(kind: .photo)
    var videos = MediaIndex(kind: .videoFrame)
    var uniqueVideoCount = 0
    var photoSimilaritySearch: SimilaritySearching?
    var videoSimilaritySearch: SimilaritySearching?
    var isMemoryPressureSuspended = false
    var memoryPressureGeneration: UInt = 0
}

struct ScoredMedia {
    let rawScores: [Float]
    let scores: [Float]
}

enum SearchCancellation {
    static let checkInterval = 256
    @TaskLocal static var additionalCheck: (@Sendable () throws -> Void)?

    static func check(_ iteration: Int) throws {
        if iteration.isMultiple(of: checkInterval) {
            try checkNow()
        }
    }

    static func checkNow() throws {
        try Task.checkCancellation()
        try additionalCheck?()
    }
}

enum BoundedTopK {
    static func select<Element>(
        from candidates: [Element],
        limit: Int,
        isPreferred: (Element, Element) -> Bool,
        cancellationCheck: (Int) throws -> Void = { _ in }
    ) rethrows -> [Element] {
        guard limit > 0 else { return [] }

        var heap: [Element] = []
        heap.reserveCapacity(min(limit, candidates.count))
        for (index, candidate) in candidates.enumerated() {
            try cancellationCheck(index)
            insert(candidate, into: &heap, limit: limit, isPreferred: isPreferred)
        }
        try cancellationCheck(candidates.count)
        return heap.sorted(by: isPreferred)
    }

    static func insert<Element>(
        _ candidate: Element,
        into heap: inout [Element],
        limit: Int,
        isPreferred: (Element, Element) -> Bool
    ) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(candidate)
            siftUp(&heap, from: heap.count - 1, isPreferred: isPreferred)
        } else if let worst = heap.first, isPreferred(candidate, worst) {
            heap[0] = candidate
            siftDown(&heap, from: 0, isPreferred: isPreferred)
        }
    }

    static func sorted<Element>(
        _ heap: [Element],
        isPreferred: (Element, Element) -> Bool
    ) -> [Element] {
        heap.sorted(by: isPreferred)
    }

    static func rows(
        count: Int,
        limit: Int,
        includes: (Int) -> Bool = { _ in true },
        isPreferred: (Int, Int) -> Bool,
        cancellationCheck: (Int) throws -> Void = { _ in }
    ) rethrows -> [Int] {
        guard limit > 0 else { return [] }

        var heap: [Int] = []
        heap.reserveCapacity(min(limit, count))
        for row in 0..<count {
            try cancellationCheck(row)
            guard includes(row) else { continue }
            if heap.count < limit {
                heap.append(row)
                siftUp(&heap, from: heap.count - 1, isPreferred: isPreferred)
            } else if let worst = heap.first, isPreferred(row, worst) {
                heap[0] = row
                siftDown(&heap, from: 0, isPreferred: isPreferred)
            }
        }
        try cancellationCheck(count)
        return heap.sorted(by: isPreferred)
    }

    private static func siftUp<Element>(
        _ heap: inout [Element],
        from index: Int,
        isPreferred: (Element, Element) -> Bool
    ) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isPreferred(heap[parent], heap[child]) else { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private static func siftDown<Element>(
        _ heap: inout [Element],
        from index: Int,
        isPreferred: (Element, Element) -> Bool
    ) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            let worstChild: Int
            if right < heap.count, isPreferred(heap[left], heap[right]) {
                worstChild = right
            } else {
                worstChild = left
            }
            guard isPreferred(heap[parent], heap[worstChild]) else { return }
            heap.swapAt(parent, worstChild)
            parent = worstChild
        }
    }
}

enum SearchResultRanking {
    static let maximumRetainedResults = SearchConfig.locationResultsCap

    static func isPreferred(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.localIdentifier != rhs.localIdentifier {
            return lhs.localIdentifier < rhs.localIdentifier
        }
        return lhs.id < rhs.id
    }

    static func locationOnlyResults(
        media: [(index: MediaIndex, candidateMask: [Bool])]
    ) throws -> SearchResponse {
        var candidates: [SearchResult] = []
        for (index, mask) in media {
            try Task.checkCancellation()
            var scores: [Float] = []
            scores.reserveCapacity(mask.count)
            for (row, isCandidate) in mask.enumerated() {
                try SearchCancellation.check(row)
                scores.append(isCandidate ? 1 : -1)
            }
            candidates.append(contentsOf: try results(
                for: index,
                scores: scores,
                threshold: 1,
                sortByScore: false
            ))
        }
        return SearchResponse(
            results: try BoundedTopK.select(
                from: candidates,
                limit: maximumRetainedResults,
                isPreferred: isPreferredLocation,
                cancellationCheck: SearchCancellation.check
            ),
            fallbackResults: [],
            filtersApplied: nil
        )
    }

    static func results(
        for index: MediaIndex,
        scores: [Float],
        threshold: Float,
        sortByScore: Bool = true
    ) throws -> [SearchResult] {
        switch index.kind {
        case .photo:
            let rows = try BoundedTopK.rows(
                count: index.count,
                limit: maximumRetainedResults,
                includes: { scores[$0] >= threshold },
                isPreferred: sortByScore
                    ? { preferredScoredRow($0, $1, scores: scores, in: index) }
                    : { preferredLocationRow($0, $1, in: index) },
                cancellationCheck: SearchCancellation.check
            )
            var results: [SearchResult] = []
            results.reserveCapacity(rows.count)
            for (resultIndex, row) in rows.enumerated() {
                try SearchCancellation.check(resultIndex)
                results.append(try result(for: index, row: row, score: scores[row]))
            }
            return results

        case .videoFrame:
            // Database video rows are grouped by video ID and ordered by frame
            // position. Flush one best frame per contiguous video into a bounded
            // heap so memory does not scale with the total video count.
            var retained: [SearchResult] = []
            retained.reserveCapacity(min(maximumRetainedResults, index.count))
            var currentID: String?
            var currentBest: SearchResult?

            func retainCurrentBest() {
                guard let currentBest else { return }
                BoundedTopK.insert(
                    currentBest,
                    into: &retained,
                    limit: maximumRetainedResults,
                    isPreferred: isPreferred
                )
            }

            for row in 0..<index.count {
                try SearchCancellation.check(row)
                guard scores[row] >= threshold else { continue }
                let result = try result(for: index, row: row, score: scores[row])
                if result.id == currentID {
                    if let existing = currentBest, result.score > existing.score {
                        currentBest = result
                    }
                } else {
                    retainCurrentBest()
                    currentID = result.id
                    currentBest = result
                }
            }
            retainCurrentBest()
            try Task.checkCancellation()
            return BoundedTopK.sorted(retained, isPreferred: isPreferred)
        }
    }

    private static func result(
        for index: MediaIndex,
        row: Int,
        score: Float
    ) throws -> SearchResult {
        switch index.kind {
        case .photo:
            return SearchResult(
                id: index.ids[row], score: score,
                localIdentifier: index.localIdentifiers[row],
                creationDate: index.dates[row], isVideo: false,
                bestFramePosition: nil, sourceId: index.sourceIds[row],
                filePath: index.filePaths[row]
            )
        case .videoFrame:
            guard let framePosition = index.framePositions[row] else {
                throw SearchEngineError.corruptedIndex
            }
            return SearchResult(
                id: index.ids[row], score: score,
                localIdentifier: index.localIdentifiers[row],
                creationDate: index.dates[row], isVideo: true,
                bestFramePosition: framePosition, sourceId: index.sourceIds[row],
                filePath: index.filePaths[row]
            )
        }
    }

    private static func preferredScoredRow(
        _ lhs: Int,
        _ rhs: Int,
        scores: [Float],
        in index: MediaIndex
    ) -> Bool {
        if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
        return preferredLocationRow(lhs, rhs, in: index)
    }

    private static func preferredLocationRow(
        _ lhs: Int,
        _ rhs: Int,
        in index: MediaIndex
    ) -> Bool {
        let lhsDate = index.dates[lhs] ?? .distantPast
        let rhsDate = index.dates[rhs] ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if index.localIdentifiers[lhs] != index.localIdentifiers[rhs] {
            return index.localIdentifiers[lhs] < index.localIdentifiers[rhs]
        }
        return lhs < rhs
    }

    private static func isPreferredLocation(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.localIdentifier != rhs.localIdentifier {
            return lhs.localIdentifier < rhs.localIdentifier
        }
        return lhs.id < rhs.id
    }
}
