# Evaluate search relevance

Use the relevance gate to detect regressions in model artifacts, preprocessing, scoring, and response thresholds.

## Understand the fixture

The gate uses 50 deterministic rows from `LIME-DATA/COCO-Caption2017` (`default/train`, rows 0 through 49) at revision `b14474455722b8c56eb7cdeb3f6be76fca1bba7a`. Each query uses the first available human caption for its image.

The repository stores fixture metadata, labels, and SHA-256 hashes. It stores downloaded images only in the gitignored `.relevance-cache/` directory.

## Run the baseline

Prepare or verify the fixture cache, then run the simulator-derived baseline:

```bash
python3 scripts/relevance.py run
```

The command verifies the pinned dataset revision, manifest fields, and image hashes. It may access the pinned dataset service when the cache or remote metadata needs verification, but it does not send application source code, user media, or review context.

The isolated `MemorableRelevanceTests` scheme uses the production `ImageEncoder`, `TextEncoder`, and `SearchEngine`. The default `Memorable` test action does not include this scheme. Simulator Core ML execution uses the CPU-only production simulator configuration.

The baseline also limits the fraction of queries that return only near-miss fallback results. This check prevents a threshold regression from preserving recall by moving the result set out of the primary response.

## Everyday queries

The same command also runs `EverydaySearchTests` against the 50 pinned photos, four committed text-search fixtures, and a deterministic booking screenshot rendered with UIKit. It uses the production image and text encoders, Apple Vision OCR, and a real in-memory GRDB database. Screenshot text uses accurate OCR; the other fixtures use fast OCR. Scene labels are omitted to isolate visual and text retrieval.

`MemorableRelevanceTests/Fixtures/everyday-queries.json` defines 12 queries: short visual descriptions, business names, document text, a reservation number, and two searches with no correct answer. Each positive query names known relevant assets. These labels are retrieval checks, not exhaustive precision annotations.

The test reports the first relevant rank in **main results** and **optional closest matches** separately. It requires a known relevant photo in the first five main results, with two explicit exceptions: `dog` and `black cat` currently rank correctly only in optional results. These are known misses, not main-result successes. The exceptions require a relevant optional result in the first five and accept a future improvement to main results. No-answer queries must keep the main grid empty. Required text matches and result uniqueness are checked separately.

The latest diagnostic ranking is written to `.relevance-cache/everyday-search-report.txt`. The original 50-caption baseline remains unchanged. Do not lower its relevance gates or add fallback exceptions to make a regression pass.

The small fixture does not establish relevance across all personal libraries. In particular, the short-query scores overlap a nonsense query's score, so this change preserves the production visual cutoff rather than lowering it globally.

## Verify bundled model artifacts offline

Run the model verifier before building or evaluating:

```bash
python3 scripts/verify_models.py
```

This command performs no network requests. It reads `scripts/model_manifest.json`, verifies the size and SHA-256 digest of every bundled Core ML file, rejects symbolic links and paths outside `Memorable/Models`, and rejects unmanifested files. Dependency-aware Xcode phases run the verifier when model inputs change and again after Xcode copies the model bundles into the app.

If you intentionally replace or recompile a model, review its source and license, regenerate every manifest size and digest, and run the relevance baseline before accepting the new artifact. Do not weaken or bypass the manifest check to make a local build pass.

The model manifest pins the upstream revision and records the conversion environment and tensor contract. Treat the compiled artifact hashes as the release identity. Update the provenance fields and hashes whenever you rebuild either model.

## Prove the gate can fail

Run the deliberate vertical-flip perturbation:

```bash
python3 scripts/relevance.py perturb
```

Expect a nonzero exit status. A passing result means the gate did not detect the known preprocessing regression.

## Sweep one scoring constant

Test candidate values for one numeric `SearchConfig` constant without committing a production change:

```bash
python3 scripts/relevance.py sweep minimumScoreThreshold=0.10,0.12,0.14
```

The sweep:

1. Refuses a dirty `AppConstants.swift`.
2. Substitutes exactly one constant.
3. Keeps metric output while skipping the fixed baseline assertion.
4. Restores the original source bytes in a `finally` block.
5. Verifies the source hash and Git cleanliness after restoration.

Interrupting the command also follows the restoration path.

## Run all pre-merge gates

Run:

```bash
python3 scripts/premerge.py
```

The command verifies bundled models first, checks migration deletion safety, and then runs the relevance baseline. A model-manifest failure stops the pipeline before Xcode packages an unapproved artifact.

## Preserve resource bounds

Relevance changes must preserve production safety limits. Keep queries at or below 500 characters, search responses at or below 500 results, duplicate review at or below 2,000 retained pairs and 5,000,000 comparisons, and folder scans at or below 100,000 supported files. Keep long-running work cancellable and confirm that memory warnings cannot repopulate a suspended index.
