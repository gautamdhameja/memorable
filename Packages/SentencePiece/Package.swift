// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SentencePiece",
    platforms: [.iOS(.v17)],
    products: [.library(name: "SentencePiece", targets: ["SentencePieceNative"])],
    targets: [
        .binaryTarget(name: "SentencePieceNative", path: "SentencePieceNative.xcframework")
    ]
)
