# Upstream tokenizer and 2,006-image simulator validation

Completed on 5 September 2026 (Europe/Berlin), on branch `v2` at
`4d5efcc9fb6369988aef3bcc2d8d652b29a08a97` plus local changes. No commit or push.
This follows the [full codebase/search review](2026-09-04-search-correctness-review.md).

Google SentencePiece **v0.2.2** now performs tokenization. The handwritten Swift
vocabulary tables, merge algorithm, scalar splitting, byte fallback and cache
have been removed. The retained code is a narrow C ABI bridge and SigLIP2 input
adapter. There is no handwritten protobuf decoder and no edited generated code.

## Changes by file

| Files | Change and reason |
|---|---|
| `Memorable/Core/Tokenizer.swift` | Delegates to SentencePiece, preserves length-delimited UTF-8, derives EOS/pad IDs from the loaded processor, serializes native access, and throws on invalid output lengths or native failures. |
| `Memorable/Core/TextEncoder.swift` | Propagates tokenizer failures in both encoding paths and removes duplicate lowercasing. |
| `Memorable/Core/PerformanceMetrics.swift` | Records native load time instead of removed Swift table-building phases. |
| `Packages/SentencePiece/Bridge/*` | Owns native lifetime, status/exception conversion and bounded token copying; contains no tokenization algorithm. |
| `Packages/SentencePiece/Package.swift`, `CMakeLists.txt`, `SentencePieceNative.xcframework` | Local package with unmodified upstream inference code and Abseil 20260526.0, built for iOS arm64 and simulator arm64/x86_64. |
| `scripts/build_sentencepiece.py` | Rebuilds from checksum-pinned archives using upstream CMake and Apple's XCFramework packager. Recreates source directories from verified archives so cached local edits cannot silently enter a rebuild. |
| `Packages/SentencePiece/README.md`, `LICENSES.txt`, `Memorable/Resources/SentencePiece-LICENSES.txt` | Documents provenance, alternatives, rebuild instructions, boundary behavior and upstream licenses. |
| `project.yml`, `Memorable.xcodeproj/project.pbxproj` | Adds the local package and bundled notices; regenerated with XcodeGen. |
| `MemorableTests/TokenizerModelParserTests.swift` | Independent reference IDs for 23 cases, EOS/padding/truncation boundaries, invalid lengths, malformed models and missing special tokens. Uses existing generated SwiftProtobuf types for model test fixtures. |
| `MemorableTests/TokenizerConcurrencyTests.swift` | Compares 2,500 concurrent native calls with sequential output; propagates test errors. |
| `MemorableTests/SimulatorDatasetHarnessTests.swift` | Checks date/location constraints for every returned photo, plus duplicate media and descending score order. |
| `AGENTS.md`, `CLAUDE.md` | Documents the established implementation and removes obsolete custom-cache guidance. |

The reference tests exposed and fixed a preprocessing defect: Foundation's
whitespace character set includes U+200B ZERO WIDTH SPACE, while Python's
`str.split()` preserves it. The adapter now uses Foundation's regular-expression
implementation with Python-compatible whitespace semantics. It also handles
Python's U+001C through U+001F separators. The original failing reference case
remains in the tests.

The native build used 271 SentencePiece files and 1,594 Abseil files verified
byte-for-byte against the pinned archives. The archive hashes and exact upstream
revision are documented in the build script and package README. Standard Xcode
builds use the included XCFramework; they do not invoke the downloader.

## Verification

| Check | Result |
|---|---|
| Final full Debug suite, iPhone 17 Pro / iOS 26.5 | **872 passed, 0 failed, 1 skipped** |
| Opt-in 2,006-image harness, first run | **163 query cases passed**, 17,096 surfaced results checked |
| Opt-in harness after rebuilding the full image index | **163 query cases passed**, 18,522 surfaced results checked |
| Release entitlement lifecycle | **1 passed** |
| Release application build and launch | Passed |
| Unsigned Release build and static analysis | Passed, no reported diagnostics |
| Python script suite | **31 passed** |
| Pre-merge gates | Signing hygiene, model integrity, migration safety and relevance passed |
| Pinned 50-query relevance | Recall@10 **0.96**, recall@50 **0.96**, MRR **0.853333**, fallback **0.16**; unchanged |
| Native rebuild source checks | Cached source edit replaced; corrupted archive rejected |

The one skipped test in the ordinary suite is the opt-in dataset mutation harness;
it was explicitly enabled and passed twice on **Memorable Release 2K**
(`14E94DD6-98CD-4763-B3AD-93F93F81948A`). Both runs used all 2,006 seeded images,
the real bundled Core ML text model, and the production search engine. Each ran
112 Pro and 51 basic-policy query cases. The report checks finite scores,
deduplication, ordering, structured filters, expected empty cases and free-tier
restrictions. It does not assert that every semantic result is subjectively relevant;
the separate pinned relevance evaluation measures retrieval quality.

The first corpus run had 180 ms median / 212 ms p95 query latency. The refreshed
run had 994 ms median / 1,621 ms p95. These simulator measurements varied and are
not a device performance claim. Both raw reports are retained:

- [Initial query report](evidence/2026-09-04-tokenizer/query-report.json)
- [Refreshed-index query report](evidence/2026-09-04-tokenizer/query-report-refreshed.json)

The Release UI correctly searched 500 of 2,006 items with no Pro entitlement,
returned a dog carrying a ball for "dog running with ball," and explained that
"California 2022" requires Pro filters. The development build then restored the
full **2,006 indexed photos**, confirmed by SQLite and application logs. Its UI
returned **16 dog-and-ball results** and **8 California/2022 results**, displaying
both filter chips. Screenshots:

- [Release dog search](evidence/2026-09-04-tokenizer/release-dog-search.jpg)
- [Release filter gate](evidence/2026-09-04-tokenizer/release-pro-filter-gate.jpg)
- [Full-library dog search](evidence/2026-09-04-tokenizer/full-library-dog-search.jpg)
- [Full-library California/2022 search](evidence/2026-09-04-tokenizer/full-library-california-2022.jpg)

## Code review results

**Scope:** tokenizer replacement, native package/build boundary, changed encoder
call sites, metrics, tests, harness assertions and associated documentation.
The earlier branch-wide fixes are covered by the linked full review and the final
regression suite. New package/build files were included in this follow-up even
though they remain untracked with the rest of the uncommitted work.

**Intent:** replace custom standard-library behavior with the upstream reference
implementation while preserving SigLIP2 inputs, error handling and search quality.

**Mode:** local review and authorized fixes. The simplify pass covered reuse,
quality and efficiency. The final review covered correctness, project standards,
testing, maintainability, security, performance, reliability, adversarial failure
scenarios and Swift/iOS ownership and concurrency. These follow-up passes ran
inline in the current local task under the repository's sequential tool mapping;
they are not independent reviewers. No source, diff, test output or review context
was sent to an external model or hosted review service.

### Actionable Findings

None remain. The native source-cache check and special-token error-path coverage
were tightened during the local review and verified. No speculative refactor or
new custom tokenizer implementation was introduced.

### Coverage

The bridge's byte lengths, zero-capacity output, EOS reservation, token bounds,
native lifetime, lock scope and failure paths were traced and exercised. Package
linkage and both Debug/Release paths were built. Upstream implementation files
were verified against release archives; they were not reimplemented or manually
audited line by line. Findings mechanics completed with no malformed or suppressed
findings; no remaining finding required a validator batch. Cross-model review was
disabled by the user's explicit privacy requirement.

The corpus contains photos, not videos. Existing automated video tests passed,
but this corpus run supplies no real-video integration evidence. Foundation Models
timed out on the simulator and the production parser fallback handled the queries.
Physical-device GPU/Neural Engine execution remains untested. The locking/ABI review
and simulator tests do not prove every possible native failure or concurrency
interleaving absent.

### Verdict

**Ready with fixes applied locally. Actionable findings: none.**

Detailed local review artifacts: `/tmp/memorable-tokenizer-review-20260904`.
