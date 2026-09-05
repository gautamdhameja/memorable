# Query ranking diagnosis

Query: pulse heart centre. Reproduced using the 2,006-photo simulator library.

Observed parser output: visual=true, no location, date, time or exclusion constraint. Raw and boosted scores were identical, so OCR/scene boosts did not cause this reproduction.

Top raw score: 0.0969. Mean: 0.0244. Zero candidates passed 0.12. The adaptive photo rule accepted a cluster of at least three scores within 80% of the leader and replaced the cutoff with 60% of the leader, approximately 0.05814. Result: 46 normal results, scores 0.0582–0.0969. This rule exists in both resident and paged ranking. The diagnostic Results log prints the nominal threshold even when the effective threshold was reduced.

Experiment: remove both adaptive blocks and leave the 0.12 cutoff fixed; collapse near misses behind a disclosure. This produced no normal matches for the reported query. Regression checks covered weak clusters in resident/paged search and a full OCR name match. 890 unit tests passed, one opt-in test skipped.

The required real-model gate failed: fallback query rate rose from 0.16 to 0.26, above the 0.18 allowed bound. Recall@10/50 stayed 0.96 and MRR stayed 0.853333, with rankings evaluated using fallback when normal results are empty. Legitimate descriptive queries also had sub-threshold scores, including bike brakes (0.1084) and kitchen descriptions (0.1087–0.1162). The experiment was reverted; the baseline and tolerance were not weakened. Earlier home continuity and index-reset history changes were preserved.

Recommendation: evaluate literal-name/text intent and visual descriptions separately before replacing the promotion rule. The current OCR implementation is a soft per-word substring boost, not exact-name retrieval. This investigation establishes why weak visual guesses become normal results; it does not establish whether the user's desired photo has a complete OCR match on their device.
