# Startup, Search, and Indexing Changes - Before and After

Date: 2026-06-06

This document summarizes the functional and behavioral changes from the current implementation work. It is written for product and engineering review, so it focuses on how the app behaves before and after the change rather than walking through the code.

## Executive Summary

Before this work, Memorable treated launch as a single large initialization step. The app waited for Core ML encoders, search engine setup, and index loading before the main experience could become usable. That made startup slower, especially on large libraries or after an interrupted indexing session.

After this work, launch is staged. The app brings up the visible shell first, then warms semantic search in the background. If the user searches before background warmup finishes, that work is promoted to user-initiated priority. The goal is faster perceived startup without making actual search slower when the user needs it.

The implementation also tightens privacy and correctness in search. Location query text is no longer sent to `CLGeocoder`; location filtering now relies on locally stored reverse-geocoded metadata and trusted coordinates already attached to indexed media. Index loading and reloads are moved off the main actor, reducing UI blocking risk.

## High-Level Behavior Change

| Area | Before | After |
| --- | --- | --- |
| App launch | Startup waited for model and index work before the app was considered loaded. | The app shell becomes ready first, then semantic search warms after first paint. |
| Search readiness | The app exposed a single `isModelLoaded` style state. | Readiness is split into shell, semantic model, and index states. |
| First search | Search could be unavailable or blocked until setup finished. | A user search promotes warmup priority and waits for semantic readiness only when needed. |
| Index loading | Existing indexes were loaded as part of launch flow and could run on the main actor. | Index loading runs through detached work with explicit readiness callbacks. |
| Auto-resume indexing | Incomplete indexing checks could happen immediately during launch. | Auto-resume is deferred after launch and only runs if there is already an existing index. |
| Location search privacy | Query-derived location text could be forward-geocoded. | Query location text is matched locally against stored metadata; no query text is sent to geocoding. |
| Memory warning handling | Search index was dropped directly. | Index is dropped and readiness state is also marked unavailable. |
| User feedback | The UI mainly showed generic loading or indexing state. | The UI distinguishes warming search, prioritizing search, waiting for index, failure, and retry states. |

## Startup Flow

### Before

On launch, the app initialized the heavy semantic components as part of the main startup sequence:

1. Load the image encoder.
2. Load the text encoder.
3. Create the search engine.
4. Create the indexing service.
5. Load the existing search index.
6. Mark the app model as loaded.

That made the first usable UI depend on model and index readiness. If model creation or index loading was slow, the user saw startup/loading state for longer.

### After

Startup now has separate readiness phases:

1. Check photo library authorization.
2. Mark the app shell ready.
3. Show the main UI.
4. Start semantic search warmup after the shell is ready.
5. Load encoders and search engine in the background.
6. Load the existing index in detached work.
7. Mark semantic search ready when both model and index are ready.

This makes the app feel faster because the first visible screen is no longer blocked by the complete semantic search stack.

## Semantic Search Warmup

### Before

Semantic search setup happened as part of initialization. There was no explicit distinction between background warmup and a user actively trying to search.

### After

A new semantic runtime tracks search setup with clear phases:

- `idle`
- `warmingCore`
- `waitingForIndex`
- `ready`
- `failed`

Warmup starts as post-paint background work. If the user searches while warmup is still running, the runtime promotes that work to user-initiated priority. The UI then says "Prioritizing search..." instead of continuing to look like passive background setup.

This keeps startup light while still protecting the first real search interaction.

## Search UI Behavior

### Before

The search field was disabled until indexing was ready. If setup was not complete, the placeholder generally implied indexing was still in progress. The UI had less visibility into whether search was waiting on model setup, index loading, or an actual failure.

### After

The search UI remains interactive and reflects the current semantic state:

- "Preparing search..." during initial setup.
- "Warming search..." during background semantic warmup.
- "Prioritizing search..." when the user initiates a search before warmup has finished.
- "Index your photos to search..." when the semantic model is ready but no index is available.
- "Search setup failed" if warmup fails.

When the search stack fails to warm, the app shows a retry path instead of leaving the user stuck.

The search result loading state is also more specific. If semantic search is not ready yet, the app shows "Getting search ready..." rather than a generic "Searching...".

## Stale Search Result Protection

### Before

If a user typed quickly or changed the query while an earlier search was still running, stale results could potentially land after the query had changed.

### After

The search view cancels prior search tasks when the query changes and checks that the active text still matches the query before applying results. This reduces race conditions where results for an older query appear under newer search text.

## Index Loading and Indexing Behavior

### Before

Existing index loading was part of startup and could be coupled to work that fetched the photo library, cleaned orphaned embeddings, and checked for incomplete indexing. That made startup more expensive.

### After

Index behavior is more staged:

- Existing photo and video index counts are checked first.
- If there is an existing index, the search index is loaded off the main actor.
- Readiness callbacks mark the index ready or unavailable.
- Orphan cleanup is optional and skipped for user-initiated search warmup.
- Auto-resume of incomplete indexing is delayed until after launch.
- A brand-new user with no existing index is not auto-indexed just because the app launched.

This reduces launch-time work and avoids surprising brand-new users with automatic indexing.

## Free Tier Counting

### Before

The free tier logic was more photo-oriented. Some paths counted already indexed photos without consistently including videos.

### After

Indexing counts photos and videos together as indexed media. The UI copy also now says "photos & videos" or "media" where the behavior includes both. Resume indexing text now says "Index remaining media" instead of "Index remaining photos".

This makes the freemium limit and UI language match the actual media indexing model.

## Video Search Filtering

### Before

Video filtering logic for date and location appeared in multiple places. That made it easier for fallback results, normal ranking, and sparse-result behavior to drift from each other.

### After

Video hard-filter logic is centralized. Date and location checks now use the same helper for video candidate counting, normal video ranking, and fallback grouping behavior.

This should make video search behavior more consistent across normal results and fallback states.

## Negative Search Terms

### Before

Negative terms could trigger broader scoring work than necessary, including repeated full-matrix style paths.

### After

Negative term scoring is candidate-aware. For photos and videos, the code computes the negative penalty only for candidates that passed hard filters, and reuses row buffers for CPU scoring.

User-facing behavior should remain the same: negative terms still lower the score of matching results. The performance profile should be better, especially when filters narrow the candidate set.

## Location Search Privacy

### Before

When the parser extracted a location name from a query, the search engine could forward-geocode that text through `CLGeocoder`. For example, a user query containing a place name could result in that place text being sent to Apple location services.

### After

Search no longer forward-geocodes query-derived location text. Location filtering is local-first:

- Match query location text against stored city, state, country, and location name metadata.
- Use GPS distance only when trusted coordinates already exist in query hints.
- Continue reverse-geocoding indexed media coordinates separately so local metadata can improve later searches.

The important privacy change is that photo contents and search query location text stay on device during search.

## Memory Warning Behavior

### Before

On memory warning, the app dropped the search index.

### After

On memory warning, the app drops the search index and updates readiness state so the UI and semantic runtime know the index is no longer available.

That makes the system state more accurate after memory pressure.

## Purchase and Refund Handling

### Before

The refund callback trimmed the index to the free-tier limit, but launch timing could make entitlement verification race with callback setup.

### After

After wiring the refund callback, the app explicitly re-verifies entitlement. If Pro has been revoked, the index is trimmed to the free-tier media limit and the search index reloads.

This makes refund handling more reliable.

## Model Resource Handling

### Before

Model resource lookup was embedded more directly in encoder setup.

### After

A model resource manager describes the active packaging strategy and validates bundled Core ML model resources. Missing model resources now produce a structured unavailable error message.

This does not change the current packaging strategy. Models are still bundled in the app. It creates a clearer boundary for future model packaging work, such as downloadable or separately quantized models.

## Performance Observability

### Before

Startup and search performance were mostly visible through ad hoc debug logs.

### After

The app has named debug performance phases:

- `launch.to_shell`
- `semantic.warmup`
- `search.first_query`
- `search.warm_query`
- `index.load`
- `indexing.throughput`
- `ui.main_thread_responsiveness`

This makes it easier to compare launch-to-shell time, semantic warmup time, and index loading time during local profiling.

## Documentation Changes

The project documentation was updated to reflect the new behavior:

- Search scoring docs now describe local-only location matching.
- Product docs now better describe photos and videos as indexed media.
- The startup/search plan and brainstorm documents remain under `docs/plans` and `docs/brainstorms`.

## Verification Status

The following checks passed locally:

- Swift parser check on the touched app and test files.
- `git diff --check`.
- Targeted stale-symbol search for removed or renamed code paths.
- Package resolution during destination listing resolved `GRDB 7.10.0` and `SwiftProtobuf 1.36.1`.

The full simulator build and test run could not be completed on this machine because the local Xcode simulator installation is inconsistent:

- Xcode: `26.5 (17F42)`.
- Installed SDKs include `iPhoneSimulator26.5.sdk`.
- CoreSimulator is older than the Xcode build expects: current `1051.49.0`, expected `1051.54.0`.
- `xcodebuild` cannot load simulator devices.
- The requested `iPhone 17 Pro` simulator destination is unavailable.
- The physical-device placeholders are also ineligible because Xcode reports iOS `26.5` as not installed through `Xcode > Settings > Components`.

Because of that environment issue, simulator launch, full app build, and XCTest execution remain unverified locally even though the static checks above passed.

## Expected User Impact

The intended user-facing impact is:

- Faster perceived app startup.
- Less chance that launch stalls on model or index work.
- Search still becomes high priority when the user actually tries to search.
- Clearer UI states while search is warming or unavailable.
- More reliable search behavior when typing quickly.
- More accurate media language for photos and videos.
- More private location search behavior.
- More consistent video filtering and fallback behavior.
- Safer memory-warning recovery.
- More reliable refund/free-tier enforcement.

## Main Tradeoffs

This implementation intentionally shifts some work from launch time to shortly after launch or to the first search interaction. That improves startup responsiveness, but it means the first search after a cold launch may briefly show "Getting search ready..." if background warmup has not finished yet.

The mitigation is priority promotion: a user-initiated search does not wait behind passive background work. The app treats that search as the important task and prioritizes semantic readiness.

