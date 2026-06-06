import Foundation

enum ReadinessStatus: Equatable {
    case unavailable
    case warming
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct AppReadiness: Equatable {
    var shell: ReadinessStatus = .unavailable
    var semanticModel: ReadinessStatus = .unavailable
    var index: ReadinessStatus = .unavailable

    var isShellReady: Bool { shell.isReady }
    var isSemanticModelReady: Bool { semanticModel.isReady }
    var isIndexReady: Bool { index.isReady }
    var isSemanticSearchReady: Bool { semanticModel.isReady && index.isReady }

    mutating func markShellReady() {
        shell = .ready
    }

    mutating func markSemanticModelWarming() {
        semanticModel = .warming
    }

    mutating func markSemanticModelReady() {
        semanticModel = .ready
    }

    mutating func markIndexWarming() {
        index = .warming
    }

    mutating func markIndexReady() {
        index = .ready
    }

    mutating func markIndexUnavailable() {
        index = .unavailable
    }

    mutating func markSemanticFailure(_ message: String) {
        semanticModel = .failed(message)
    }
}
