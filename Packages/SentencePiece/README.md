# SentencePiece for Memorable

This local Swift package contains Google's **SentencePiece v0.2.2** inference
library, built from unmodified upstream source, plus a small C ABI bridge.
`CLIPTokenizer` applies SigLIP2's lowercase/whitespace preprocessing and its
64-token EOS/padding contract. It contains no tokenizer algorithm or cache.

## Upstream pins

- [SentencePiece v0.2.2](https://github.com/google/sentencepiece/tree/v0.2.2),
  commit `e0cce7d37b065b5140349dbe12c6bcf6192fdd78`.
- [Abseil 20260526.0](https://github.com/abseil/abseil-cpp/tree/20260526.0),
  the version required by that SentencePiece release.
- SentencePiece's bundled Protobuf Lite and Darts Clone implementations.

The XCFramework includes iOS arm64 and simulator arm64/x86_64 static libraries,
with deployment target iOS 17. Only inference is linked; training and command-line
executables are not shipped. Abseil archives are combined with SentencePiece so
the app needs no separately resolved native dependencies. `LICENSES.txt` is also
copied into the application resources.

## Rebuild

Install CMake and Xcode, then run from the repository root:

```sh
python3 scripts/build_sentencepiece.py --work-dir /tmp/memorable-sentencepiece-build \
  --output /tmp/RebuiltSentencePieceNative.xcframework
```

The script verifies SHA-256 checksums of both release archives before extraction,
uses upstream CMake builds, and packages them with Apple's XCFramework tool.
Choose a new output directory when rebuilding. After validation, replace the
checked-in `SentencePieceNative.xcframework` with the rebuilt output. Ordinary app
builds use the checked-in artifact and do not download or execute this script.
Run `xcodegen generate` after changing package/project configuration.

## Boundary and verification

The bridge only loads serialized model bytes, calls `SentencePieceProcessor.Encode`,
copies a bounded prefix of token IDs, exposes EOS/pad IDs, and owns native lifetime.
Inputs have explicit byte lengths, so embedded NUL is preserved. C++ errors and
exceptions become Swift errors. Swift serializes processor access under a lock;
no native pointer escapes it. The adapter accepts output lengths 1–64 and always
reserves the last available position for EOS.

`TokenizerModelParserTests` compares against IDs independently generated with
the official Python SentencePiece 0.2.1 release and the bundled Gemma model.
Cases cover multilingual/combining text, emoji, byte fallback, punctuation,
whitespace, NUL, special-token strings, and truncation. `TokenizerConcurrencyTests`
compares 2,500 concurrent calls with sequential output. Encoder and seeded-library
search tests exercise the actual Core ML input and retrieval path.

## Alternatives checked

- Apple's `NLTokenizer` finds linguistic boundaries; it does not produce this
  model's SentencePiece vocabulary IDs.
- Hugging Face `swift-transformers` Tokenizers supports an offline tokenizer JSON
  pipeline, but would require converting and validating new tokenizer assets.
- Community Swift SentencePiece wrappers expose older prebuilt upstream versions.

The official library consumes the existing `.model` directly and owns the complete
normalizer/BPE/byte-fallback semantics. The bridge is solely a language/ABI adapter.
Apple SwiftProtobuf and the existing generated model types remain available for
the application's protobuf compatibility tests. No handwritten protobuf decoder
is introduced.
