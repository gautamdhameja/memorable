# Home memory card layout verification

Date: 2026-09-05. Branch: v2.

Portrait photos use a 164 × 218-point preview with the date and summary beside it. Landscape and square photos retain the 156-point preview and 62-point caption below. Both layouts occupy the same 218-point card height at standard text sizes. The existing aspect-fit image loader preserves the full photo, with a blurred backdrop filling unused space. Missing or invalid dimensions retain the landscape layout.

## Simulator checks

Tested the Debug app on Memorable Release 2K with its existing 2,010-image library. The normal landscape hero and an existing portrait from today's memories used the actual home card, PhotoKit loader, and navigation. A temporary launch argument selected the portrait in memory; stored photos, dates, indexing, and search history were not modified. All temporary QA code was removed before the final tests and build.

- Landscape: original card footprint retained; recent searches remain visible below it.
- Portrait: full photo displayed beside the date; card and Recent Searches begin and end at the same vertical positions as the landscape example. Three complete recent search rows remain visible in both screenshots.
- Narrow layout: constrained the card to 288 points, corresponding to a 320-point screen with the existing horizontal insets. The date wraps without clipping or increasing the card height.
- Accessibility: set the card's Dynamic Type environment to accessibility3. The caption remains readable and expands the card instead of truncating text. This checks the card's typography, not every screen at that setting.
- Tapping the portrait card opens On This Day and its existing memory content.

Screenshots: landscape.jpg, portrait.jpg, portrait-narrow.jpg, portrait-large-text.jpg.

## Automated verification

- Full simulator suite: 897 passed, 0 failed, 1 opt-in test skipped. Result bundle: `~/Library/Developer/XcodeBuildMCP/workspaces/memorable-677c76a4ffa5/result-bundles/test_sim_2026-09-05T18-13-50-015Z_pid37482_01cbf9c3.xcresult`.
- Updated the existing home-card configuration check for the shared SwiftUI AnyLayout caption.
- Reviewed the final diff in the main Codex task for layout constraints, image loading, Dynamic Type, navigation, and unintended search/indexing changes. No external review was used.
- git diff --check passed.
- The first two pre-merge attempts failed before tests because the simulator refused to launch the gate's cached app. `codesign --verify` reported that this artifact was unsigned; the separate build used by the successful test suite was ad-hoc signed. Cleaning and rebuilding the gate's DerivedData produced a verified signature and a successful simulator launch. No project signing settings were changed.
- The complete pre-merge gate then passed: signing hygiene, model verification, migration safety, and real-model relevance. Recall@10 and recall@50 remained 0.96; MRR remained 0.853333 and fallback rate 0.26.
- The final build, with all temporary QA controls removed, was installed and launched successfully on the seeded simulator.

No physical-device or Release build testing was performed for this layout change.

## Portrait caption refinement

The portrait caption now uses a fixed 152-point panel, with the arrow inline beside the date and summary. The photo area receives the remaining width. Its foreground and blurred backdrop are explicitly bounded to preserve the full image as that area widens; landscape sizing is unchanged. The card remains 218 points high at standard text sizes, with recent searches at the same position.

Verified with an existing portrait from the seeded simulator library; see portrait-compact-caption.jpg. The temporary in-memory hero selector was removed before the final tests. Full simulator suite: 897 passed, 0 failed, 1 opt-in test skipped.

The final build launched successfully. The landscape card was visually unchanged. All pre-merge gates passed on retry after the public dataset endpoint initially returned HTTP 502; relevance metrics remained unchanged (recall@10 and recall@50 0.96, MRR 0.853333, fallback rate 0.26).
