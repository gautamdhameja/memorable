# Vertical layout audit — September 7, 2026

Scope: every app-owned screen and shared image renderer on `v2`, after the Memories header simplification. Reviewed locally in the current Codex task. No external model or review service was used. Existing changes to Memories and its tests were preserved; `docs/ideation/` was left untouched.

## Confirmed defects and fixes

Actual SwiftUI layout measurements reproduced four additional defects before the fixes. These tests render the production view builders through `UIHostingController`; they do not duplicate layout formulas in a mock.

| Surface | Before | Fix |
| --- | --- | --- |
| Search results, including similar and recent results | At a proposed width of 190 points, a portrait changed the placeholder height from about 143 to 254 points. Extreme aspect ratios also changed width. | A stable 4:3 canvas owns layout. The initial fix fitted images inside that canvas, introducing empty bands; see the September 8 correction below. The obsolete image-dependent aspect-ratio calculation was removed. |
| Home memory card | A panoramic blurred backdrop requested 624 points of width inside a 350-point proposal. | The existing placeholder owns layout and both image layers draw in an overlay. Existing home card dimensions and portrait fill mode are preserved. Recent-search previews share this renderer. |
| Indexing slideshow | A 350-point-wide placeholder was about 263 points tall; the loaded branch requested 430 points. This displaced the progress card when the first image appeared. | Placeholder and loaded images share one 4:3 canvas, capped at 430 points. Photo changes cannot resize it. Date fades and image loading/cancellation are unchanged. |
| Duplicate comparison rows | A 190-point placeholder was about 164 points tall; loaded images forced it to 190 points. | The existing 1.16 aspect-ratio container owns layout; images fill and clip inside it without imposing a square size. |

The earlier Memories fix remains in place: thumbnails render inside metadata-sized bounds, and removing the header image restores that photo to the year grid. Around This Time uses the same corrected memory thumbnails.

## Screen coverage

| Screen or component | Audit result and verification |
| --- | --- |
| Search home and recent searches | Code trace, cold launch on the seeded simulator, home-card renderer measurements. |
| Visual/OCR search results; recent/similar result grids | Shared renderer traced through all callers. Ran the saved Mountains search (3 results), inspected OCR and visual sections, and scrolled to the video result. |
| Fallback results | Code review: an explicit flexible frame absorbs the image's size before the square aspect-ratio modifier; no matching defect found. |
| Full Memories and Around This Time | Metadata determines grid geometry before images load; shared renderer regression remains green. The audit missed the late navigation inset correction when opening Memories from Search. See the follow-up below; the original conclusion that no additional change was needed was wrong. |
| Initial/resumed/rebuild indexing slideshow | Production renderer tested with nil, portrait, landscape, panorama, and tall images. Did not restart the 2,010-photo index for this layout-only audit. |
| Incremental indexing, enrichment and location status | Reviewed their presentation conditions and background rendering. The initial/incremental state tests passed in the full suite. Status cards intentionally enter or leave when work starts/finishes; this audit does not remove those product transitions. |
| Full-screen photo viewer and zoom | GeometryReader supplies fixed viewport bounds; controls overlay the image. Viewed a rendered photo. Further control interaction could not be verified because simulator runtime UI inspection stopped exposing the controls. |
| Full-screen memory slideshow | Code review: full-screen background supplies bounds, with opacity changes and overlay controls. No scroll content whose height depends on the image. |
| Duplicate finder | Opened and started the 2,011-item library scan; UI remained responsive. Cancelled via Done after the scan exceeded the observation window. Loaded row sizing is covered by the red/green renderer tests, not a completed live duplicate scan. No photos deleted. |
| More and Photo Sources | Opened both on the seeded simulator. No image-driven sizing paths. Source/count and workflow changes are explicit content transitions. |
| Privacy, Licenses and license details | Opened each; scrolled Privacy. Static local text and stable inline navigation titles; no asynchronous image sizing. |
| Onboarding, launch, permissions, unsupported-device and recovery screens | Code review: fixed illustration frames, transforms that do not affect layout, and deliberate whole-screen state transitions. No new live onboarding/reset run. |
| Upgrade | Code review: static feature list and purchase footer; purchase/load/error state transitions remain explicit. No purchase attempted. |
| Video player, Share sheet, folder picker and alerts | Platform-owned presentations. Reviewed app presentation boundaries; no replacement layout or new custom implementation added. |
| Theme, glass controls and navigation dock | Background/overlay decoration and fixed dock dimensions. No asynchronous image-driven sizing path. |

## Verification

- New layout tests failed in all four affected renderers before the fix and passed afterward.
- Layout fixtures include portrait, landscape, panorama and very tall images at widths 125, 190, 350 and 700 points, with standard and accessibility Dynamic Type.
- Full Debug simulator suite: **948 passed, 0 failed, 1 skipped**. The skip is the opt-in dataset mutation harness.
- Isolated real-model/OCR relevance suite: **4 passed, 0 failed**.
- Complete `python3 scripts/premerge.py` rerun passed, including signing hygiene, bundled model integrity, migration safety and relevance (recall@10 0.96; MRR 0.853333).
- The first pre-merge attempt could not resolve the public dataset host inside the network sandbox. After network access was allowed, its relevance invocation failed without an assertion while the app suite was also using the simulator. Running the relevance suite alone passed, followed by a successful complete pre-merge rerun with no other simulator tests running. No test expectations were relaxed.
- `git diff --check` passed.

App verification used the Memorable Debug scheme on the “Memorable Release 2K” simulator, which contains 2,010 photos and one synthetic video. Unit/relevance tests used iPhone 17 Pro. No physical-device verification or exhaustive accessibility interaction test was performed.

## Prevention and review

The recurring mistake was treating clipping or a maximum frame as a layout constraint. Clipping changes drawing, not the size a child reports to its parent. The existing tests checked source structure and aspect-ratio calculations but did not compare placeholder and loaded layout sizes. The new tests exercise that boundary directly.

Manual review covered every changed rendering path, its call sites, resource lifecycle, accessibility modifiers and image proportions. No database, search ranking, PhotoKit request, cancellation or indexing-state behavior changed. Shared code uses SwiftUI overlay/frame APIs; no layout framework or custom algorithm was introduced.

## Follow-up: vertical jump immediately after opening Memories

The user clarified that the remaining flicker happens immediately after tapping the home memory card. The earlier renderer measurements and settled screenshots did not test the navigation transition itself.

At commit `54408e3`, a 30 fps simulator recording reproduced a 10-point downward jump: the first photo's top changed from y=379 to y=389 points at the end of the push. The navigation title, back button and content moved together. Opening the same Memories view from More kept the photo at y=389 throughout the end of the transition. Both paths used the same loaded images and memory data.

Search hid the native navigation bar and drew its own brand heading. Memories shows an inline native bar. More already kept its bar visible, which explains the difference between the two entry points.

The fix moves the Search brand into the native bar and keeps that bar visible. Launch and search preparation use the same modifier so their headings stay consistent with Search. The iOS 26 toolbar background is hidden for the noninteractive brand text. No memory data, grid sizing, indexing state, timers or artificial offsets changed.

Verification on the seeded simulator (2,010 photos and one video):

- Recorded three Search-to-Memories openings, including reopening after terminating and relaunching the app. The first photo stays at y=389 through the end of each push; the previous y=379 to y=389 correction is absent.
- Recorded More-to-Memories as a control; its photo stays at y=389.
- Checked back navigation to Search, native brand appearance, startup preparation-to-home alignment and the saved Mountains search (3 results).
- Added a navigation policy regression that failed before implementation and passed afterward. This source-structure check guards bar ownership; the recordings establish the visual result.
- Full Debug suite: **949 passed, 0 failed, 1 skipped** (opt-in dataset mutation harness). Build reported no warnings.
- Isolated relevance suite via XcodeBuildMCP: **4 passed, 0 failed**. Signing hygiene, bundled model integrity and migration safety also passed. The complete pre-merge wrapper did not pass: its first run could not reach the public dataset in the network sandbox; two network-enabled runs verified the fixtures but failed to launch the simulator test host before assertions ran. The same relevance scheme passed through XcodeBuildMCP between those runs. The wrapper launch failure remains unresolved; this is not a claim of a passing complete pre-merge gate.

Local recordings are saved in the task's `memory-opening-fix` artifact directory: `before.mp4`, `after.mp4`, `after-repeat.mp4`, `after-cold.mp4`, `more-before.mp4`, `more-after.mp4`, and `startup-after.mp4`. Coordinates were measured from frames scaled to the simulator's 402 × 874 point viewport. The initial horizontal push is expected; the check concerns vertical movement as that push finishes. This follow-up has not been verified on a physical device or older iOS versions.

## September 8: search thumbnail correction

The fixed 4:3 canvas prevented layout movement but fitting every image inside it produced empty bands around portrait photos and panoramas. Visual result previews now fill and crop within the same stable canvas. Text-match previews explicitly retain fit mode so text remains visible. The thumbnail clips drawing and constrains hit testing to its tile. Full-photo presentation is unchanged.

A rendered-pixel regression failed on the previous implementation for both portrait and panoramic images, then passed with the correction. Placeholder/loaded size checks cover both fill and fit, photos and video frames, four widths, and standard and accessibility text sizes.

Verified on the seeded Memorable Release 2K simulator in Debug: Mountains (visual photo/video and OCR), Pulse Heart Centre (two OCR matches), People (feature plus paired tiles), Recent/Relevance sorting, full-photo opening and dismissal, and Find Similar with 50 results and scrolling. Both paired tiles opened the correct numbered result. The fill implementation initially allowed content outside the tile to affect taps; constraining the content shape restored photo-button handling before handoff. The recorded run is `search-tile-fix/verification.mp4` in the September 4 Codex visualization workspace. The final targeted run passed 86 tests (DataModelTests and ProjectConfigurationTests). No physical-device verification was performed for this change.
