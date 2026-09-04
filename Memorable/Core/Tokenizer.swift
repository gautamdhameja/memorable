import Foundation
import os
import SentencePieceNative

/// SigLIP2's text-input adapter. Google's SentencePiece owns model decoding,
/// normalization, BPE and byte fallback; this class owns only the input contract.
final class CLIPTokenizer: Sendable {
    /// The processor is private to the lock and is destroyed with its owner.
    /// No native pointer escapes a locked operation after initialization.
    private final class NativeProcessor {
        let pointer: OpaquePointer

        init(pointer: OpaquePointer) { self.pointer = pointer }
        deinit { memorable_sp_destroy(pointer) }
    }

    private let processor: OSAllocatedUnfairLock<NativeProcessor>
    private let contextLength: Int
    private let eosId: Int32
    private let padId: Int32

    enum TokenizerError: LocalizedError {
        case filesNotFound
        case invalidLength
        case nativeFailure(String)

        var errorDescription: String? {
            switch self {
            case .filesNotFound:
                "The search vocabulary is missing. Reinstall Memorable and try again."
            case .invalidLength:
                "The tokenizer output length must fit within the model context."
            case .nativeFailure(let message):
                "The search tokenizer failed: \(message)"
            }
        }
    }

    convenience init(contextLength: Int = 64) throws {
        guard let url = Bundle.main.url(forResource: "tokenizer", withExtension: "model") else {
            throw TokenizerError.filesNotFound
        }
        #if DEBUG || STARTUP_METRICS
        let startedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let data = try Data(contentsOf: url)
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerFileRead,
            durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
        )
        #endif
        try self.init(modelData: data, contextLength: contextLength)
    }

    init(modelData: Data, contextLength: Int = 64) throws {
        guard (1...64).contains(contextLength) else { throw TokenizerError.invalidLength }
        self.contextLength = contextLength
        var error = [CChar](repeating: 0, count: 512)
        #if DEBUG || STARTUP_METRICS
        let startedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let pointer = modelData.withUnsafeBytes { bytes in
            memorable_sp_create(bytes.baseAddress, bytes.count, &error, error.count)
        }
        guard let pointer else {
            throw TokenizerError.nativeFailure(Self.errorMessage(error))
        }
        eosId = memorable_sp_eos_id(pointer)
        padId = memorable_sp_pad_id(pointer)
        processor = OSAllocatedUnfairLock(uncheckedState: NativeProcessor(pointer: pointer))
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerNativeLoad,
            durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
        )
        #endif
    }

    func tokenize(text: String, maxLength: Int? = nil) throws -> [Int32] {
        let length = maxLength ?? contextLength
        guard (1...contextLength).contains(length) else { throw TokenizerError.invalidLength }
        // SigLIP2 lowercases and collapses whitespace before SentencePiece.
        // ICU's Unicode whitespace plus Python's four control separators match
        // Python str.split(). Foundation's whitespace set also includes U+200B,
        // which must be preserved. Do not apply NFC/NFKC here.
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "[\\s\\u001C-\\u001F]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        var tokens = [Int32](repeating: padId, count: length)
        var error = [CChar](repeating: 0, count: 512)
        let count = processor.withLockUnchecked { native in
            cleaned.withCString { bytes in
                memorable_sp_encode(
                    native.pointer, bytes, cleaned.utf8.count,
                    &tokens, Int32(length - 1), &error, error.count
                )
            }
        }
        guard count >= 0 else {
            throw TokenizerError.nativeFailure(Self.errorMessage(error))
        }
        // Native encoding returns at most length - 1 IDs. EOS is always present,
        // including empty input and truncated queries; the remaining slots pad.
        tokens[Int(count)] = eosId
        return tokens
    }

    private static func errorMessage(_ bytes: [CChar]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
