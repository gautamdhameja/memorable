# Encoder concurrency race

## Defect

Search, surprise-query validation, and caption preparation can encode at the
same time. `CLIPTokenizer` previously mutated its word cache without
synchronization, while `TextEncoder` and `ImageEncoder` could read and replace
their `MLModel` references concurrently during prediction recovery. Caption
prompt encoding also ran on the main actor.

## Fix

- Guard tokenizer cache lookup, eviction, and writes with `OSAllocatedUnfairLock`; keep BPE
  computation outside the critical section.
- Snapshot and replace encoder model references under `OSAllocatedUnfairLock`; keep Core ML
  prediction outside the critical section and retain one reload/one retry.
- Compute caption prompt embeddings in a detached task and publish the completed
  collection on the main actor.

Regression tests exercise concurrent tokenization through cache eviction,
concurrent encoder calls with a forced reload, image batch retry, and the
single-active-job invariant of `IndexingJobQueue`.
