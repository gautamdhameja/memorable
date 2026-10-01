# Encoder concurrency race

## Problem

Search, surprise-query validation, and caption preparation can encode at the
same time. `CLIPTokenizer` previously mutated its word cache without
synchronization. Earlier encoder recovery also loaded a replacement `MLModel`
after a prediction error while the failed model was still retained. Concurrent
failures could amplify memory use at the least safe time. Caption prompt
encoding also ran on the main actor.

## Resolution

- Guard tokenizer cache lookup, eviction, and writes with `OSAllocatedUnfairLock`; keep BPE
  computation outside the critical section.
- Store each encoder model as an immutable reference protected by
  `OSAllocatedUnfairLock`. Fail a prediction closed instead of allocating a
  replacement model in the prediction path.
- Require exactly 768 values from single predictions. Require batch prediction
  count to equal input count and validate every returned embedding before use.
- Compute caption prompt embeddings in a detached task and publish the completed
  collection on the main actor.

Regression tests exercise concurrent tokenization through cache eviction,
concurrent fail-closed prediction errors, malformed single and batch outputs,
and the single-active-job invariant of `IndexingJobQueue`.
