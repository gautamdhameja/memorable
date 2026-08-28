# Smart query session concurrency

## Defect

Swift 6 migration exposed a second pre-existing concurrency defect in the smart
query path. `QueryParser` stores one process-wide `SmartQueryParser`, which in
turn stores one mutable `LanguageModelSession`.

The same instance is reachable concurrently:

- `SearchViewModel` submits a user query through `SearchEngine.search(query:)`.
- `IndexingService` runs `SurpriseQueries.validateQueries`, which calls the same
  `SearchEngine.search(query:)` entry point for every candidate.
- `SearchEngine.search(query:)` sends both paths through `QueryParser.parse` and
  the shared `LanguageModelSession`.

Apple documents that a language-model session supports only one request at a
time. A second overlapping `respond` call raises `concurrentRequests`. The
current catch block treats that like any other model failure and falls back to
the regex parser, so background validation can silently degrade a user's smart
query parsing on iOS 26.

## Fix

`SmartQueryParser` now retains only a sendable responder factory. Every parse
creates its own `LanguageModelSession`-backed responder, so overlapping searches
never share a stateful session. The parser's existing fallback behavior remains
unchanged when a response fails.

Concurrent regression coverage verifies that overlapping parses use distinct
responders. With that blocker resolved, all application and test targets now
build with Swift 6.
