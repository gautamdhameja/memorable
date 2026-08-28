# Search relevance evaluation

The relevance gate uses 50 deterministic rows from
`LIME-DATA/COCO-Caption2017` (`default/train`, rows 0–49), pinned to revision
`b14474455722b8c56eb7cdeb3f6be76fca1bba7a`. Each query is the first existing
human answer caption for its image. The repository stores only source metadata,
labels, and SHA-256 hashes; downloaded images remain in the gitignored
`.relevance-cache/` directory.

Prepare the cache, verify the current Hub revision and every manifest field and
image hash, then run the simulator-derived regression baseline with:

```bash
python3 scripts/relevance.py run
```

The isolated `MemorableRelevanceTests` scheme uses the production
`ImageEncoder`, `TextEncoder`, and `SearchEngine`. It is intentionally absent
from the default `Memorable` scheme's test action. Simulator Core ML execution
is CPU-only, matching the production encoder configuration.

The baseline also caps the fraction of queries that return only near-miss
fallback results. This prevents a threshold regression from preserving recall
by silently moving the entire result set out of the primary search response.

To prove the gate detects a preprocessing regression, run the deliberate
vertical-flip mode. A non-zero test result is expected:

```bash
python3 scripts/relevance.py perturb
```

To measure one `SearchConfig` numeric constant at a time without committing a
production-code change, pass its candidate values to the sweep command:

```bash
python3 scripts/relevance.py sweep minimumScoreThreshold=0.10,0.12,0.14
```

The sweep refuses a dirty `AppConstants.swift`, substitutes exactly one
constant, skips the baseline assertion while retaining metrics output, and
restores the original source bytes in a `finally` block. It then verifies both
the source hash and Git cleanliness. Interrupts also take the restoration path.
