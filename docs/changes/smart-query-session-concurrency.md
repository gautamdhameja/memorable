# Smart query session concurrency blocker

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

## WP6 status

WP6 remains blocked. This requires a separately reviewed runtime fix that either
serializes use of the shared stateful session or gives independent searches
independent sessions. Swift 6 settings must not be enabled until that behavior
and its concurrent regression coverage land separately.
