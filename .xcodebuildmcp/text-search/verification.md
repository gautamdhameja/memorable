# Text and visual search verification

Date: 2026-09-05. Branch: v2. Changes remain uncommitted.

## Implementation

- Complete OCR phrases qualify independently of visual similarity. Apple's NLTokenizer provides word boundaries; Foundation handles case and width normalization. Word order is required; spacing and line breaks are ignored. No new intent classifier, model, migration, or indexing pass.
- SearchResult carries an isTextMatch marker. Text matches survive resident and paged result retention, appear once in a compact horizontal section, and participate in history and the existing photo viewer.
- Removed partial-word OCR score boosts and both unfiltered and filtered weak-result promotion. The normal visual threshold remains 0.12. Weak results are hidden behind Show closest matches when neither route qualifies.
- Existing date/location/source restrictions, video deduplication, cancellation, and result limits remain in effect.

## Simulator

Memorable Release 2K, 14E94DD6-98CD-4763-B3AD-93F93F81948A, Debug build.
Preserved the original 2,006 photos. Imported four generated fixtures through simctl addmedia: clinic sign, appointment card, landscape worksheet, and an alpine river landscape. The normal app indexing and enrichment paths indexed all 2,010 images. Database counts and OCR output are recorded in index-verification.json. No embeddings or OCR values were injected.

| Query | Observed behavior |
|---|---|
| pulse heart centre | One text match (clinic sign), one visual match (appointment card), no duplicates or original weak hospital results. |
| appointment confirmation | One text match (appointment card). |
| mountains and rivers | One text match (worksheet), one visual match (landscape). Before importing the landscape, only the worksheet qualified. |
| quantum marmalade observatory | No confident matches; suggestions initially hidden. Tapping Show closest matches displays them. |
| dog | No main matches: maximum score 0.1163 is below 0.12. Fifty closest matches remain available. This is the deliberate tradeoff from removing automatic threshold relaxation. |

Tapping the clinic text thumbnail opened the photo viewer as result 1 of 2. History updated the original query from 46 results to 2, and retained text-only searches. Restarting the app preserved the index and history. Screenshots: name-results.jpg, mixed-results.jpg, no-confident-matches.jpg.

OCR recognized the appointment card as "Pulse Heart Centr Appointment confirmation", missing the final e in Centre. It correctly did not qualify for the complete-name text section. The visual route still retrieved it. Exact text matching cannot repair OCR errors or equate center with centre; fuzzy matching was not added.

## Automated checks

- Final full simulator suite: 897 passed, 0 failed, 1 opt-in test skipped. See final-tests.json for the final result bundle; test-results.json retains the earlier feature and relevance checks.
- New regressions failed before implementation for missing complete phrases, partial-text distractors, and automatic weak-cluster promotion.
- Added coverage for phrase order, word boundaries, full-width text, both resident and paged search, source/date/location restrictions, deduplication, and retaining a negative-visual-score text match amid more than 500 strong visual candidates.
- Python suite: 31 passed.
- Complete python3 scripts/premerge.py: passed, including signing hygiene, model hashes, migration safety, public dataset metadata and image hashes, and real-model relevance.
- Real-model metrics: recall@10 0.96, recall@50 0.96, MRR 0.853333, all unchanged. Fallback rate intentionally changed from 0.16 to 0.26: five more captions require Show closest matches. Only that baseline field changed; ranking expectations and the 0.02 tolerance were preserved.
- The dataset endpoint initially returned HTTP 429 twice. A later retry completed successfully. That retry overlapped a unit-test launch, killing the test runner before tests began; rerunning the unit suite alone produced the final clean result above.
- Final build-and-run and git diff --check passed.

## Review and limits

Restart testing exposed an existing smart-parser defect: a positive "mountains and rivers" query produced two model-generated exclusions despite zero explicit exclusions. The same raw top scores (0.1511 and 0.1447) fell to 0.0990 and 0.0756 after penalties, hiding the landscape. Exclusions now come only from the deterministic parser. Tests cover model-invented, omitted, and replaced exclusions. Complete OCR matching also preserves the locally parsed literal phrase when the model rewrites the visual description; resident and paged regression tests cover this separation. Temporary diagnostic probes were removed.

After the fix, three consecutive launches of the final behavior retained the worksheet text match and landscape visual match. Logs confirmed unchanged top scores of 0.1511 and 0.1447 after ranking, including successful smart-parser responses. Rechecking "pulse heart centre" returned one text match and one visual match. The final complete pre-merge run passed again with unchanged relevance metrics. Its initial sandboxed attempt could not resolve the dataset host; the authorized network-enabled retry passed. Final log: premerge-final.log.

Reviewed in the main Codex task: resident/paged eligibility and bounded retention, marker propagation through filtering/history/viewer paths, local tokenizer ownership, hard-filter masks, video behavior, and UI duplication/empty states. No project code or review material was sent to an outside reviewer. Image generation received only synthetic scene descriptions.

This verifies the Debug simulator build, not a physical device or App Store release. Real OCR quality and visual threshold calibration remain limitations. Earlier home-continuity and index-reset-history edits were preserved.
