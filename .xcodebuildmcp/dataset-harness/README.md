# Simulator dataset search verification

Run date: 2026-09-02

Simulator: `Memorable Release 2K`

Simulator identifier: `14E94DD6-98CD-4763-B3AD-93F93F81948A`

## Seeded library

- 2,006 existing images; image bytes were not modified.
- 1,622 images have deterministic GPS metadata; 384 intentionally have none.
- Capture dates span 2022 through 2026.
- Located images are distributed across Berlin, Munich, Paris, Istanbul,
  Toronto, Sydney, Tbilisi, Atlanta, New York, San Francisco, Los Angeles,
  and San Diego.
- Explicit intersections cover California 2022, Germany 2022, Berlin last
  summer, Paris December, dog in Berlin, beach in California, food in Paris,
  mountains in Bavaria, coffee in New York, and snow in December.

The simulator has no video assets, so the seven video-only queries from the
manual matrix were excluded. This run verifies the existing 2,000-photo corpus,
not video-frame indexing.

## Automated verification

- 111 Pro query cases.
- 51 free-tier executions of advanced-looking queries.
- 162/162 records passed.
- Every non-empty query surfaced primary or closest-match results.
- `Antarctica` and `dog in Antarctica` correctly surfaced no results.
- The top five visible results for every structured Pro query were reloaded
  from SQLite and checked against the requested location and date range.
- Every score was finite.
- Free searches did not apply Pro-only date or location filters and surfaced
  restriction messaging when the deterministic parser detected restricted
  intent.

See `query-report-v1.json` for per-query counts, filters, top identifiers,
scores, latency, and validation failures. See `seed-metadata-v1.json` for every
asset assignment. `original-metadata-v1.json` is the snapshot immediately
before the final acceptance run; earlier harness iterations had already seeded
the same simulator, so it is not the pristine metadata from the first import.

## Cleanup

All imported test media and seeded metadata live in the simulator above. Delete
that simulator when the dataset is no longer needed to reclaim the media and
derived index storage. The files in this directory are small audit artifacts
and can be removed independently.
