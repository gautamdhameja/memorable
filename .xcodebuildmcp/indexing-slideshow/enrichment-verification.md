# Enrichment verification

- Branch: v2; changes uncommitted.
- Main indexing presentation ends after base photos/videos. Enrichment uses a dismissible status on the normal search screen.
- Verified on Memorable Release 2K simulator with 2,006 seeded photos.
- Warm launch with unfinished enrichment: shell 0.135 s; semantic search ready 2.164 s; measured maximum main-thread stall 0.000 s.
- Submitted a dog search during analysis; results appeared, analysis paused and resumed. Dismissing the status left analysis running.
- Enrichment persisted 776 updates before interruption and 1,230 after resumption: 2,006 total. Active pass durations 52.662 s and 84.283 s. These are simulator observations, not a comparative speedup or a device benchmark.
- Aggregate Vision stage durations dominated image loading and sharpness; stage totals overlap because two photos run concurrently.
- Targeted tests: 237 passed.
- Full simulator suite: 887 passed, 1 skipped (opt-in SimulatorDatasetHarnessTests data-mutation harness).
- Pre-merge signing, bundled model, migration safety and relevance gates passed. Relevance: recall@10 0.96, recall@50 0.96, MRR 0.853333.
- Final build and git diff --check passed.
- Local review: complete, no unresolved findings. No external model or review service used.
- Physical iPhone throughput and memory measurements were not performed.
