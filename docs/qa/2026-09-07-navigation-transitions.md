# App-wide navigation transition verification

The earlier Memories verification did not cover every navigation route. This follow-up checks the same root cause throughout the app: changing native navigation-bar visibility during a push can cause a late vertical inset correction. The pre-fix recording and 10-point measurement are in [the layout audit](2026-09-07-layout-audit.md).

## Code coverage and prevention

Reviewed every SwiftUI navigation stack, link, title, sheet and full-screen cover in `Memorable`, including the UIKit video-player presentation. With the pending Search fix, no app-owned route hides a native navigation bar. Search, launch and preparation use `celestialSearchNavigation()`; More keeps its native bar visible; all titled destinations use `celestialNavigationTitle()`.

Added `testEveryScreenKeepsNavigationBarVisibilityAndTitleModeStable` in the existing project configuration suite. It scans all app source, rejects non-visible navigation-bar settings, rejects non-inline title modes, and rejects legacy bar-hiding APIs. Its visibility expression detects the `.hidden` setting in the previous committed Search implementation. This guards the known cause, not every possible UIKit animation defect.

The project instructions now require UX fixes to trace shared causes across screens and verify transitions. The release checklist includes every navigation family, cold launch, loading states, older iOS and accessibility text sizes. Source tests and settled screenshots explicitly do not replace recordings.

No further production layout changes were justified by this audit. The pending shared Search/navigation fix remains intact. No source registration, photo deletion, purchase, or index reset was performed.

## Live simulator coverage

Recorded at 30 fps on iOS 26. Reviewed frames during transitions and after they settled, including samples at 0.3, 0.5, 0.7, 0.9, 1.1, 1.5 and 2 seconds after each action. Normal sheet/push animations are expected; the defect is an additional vertical correction as or after they finish.

| Surface or route | Verification |
| --- | --- |
| Search → Memories → Search | Three recorded openings, including cold launch, in the immediately preceding fix. First-photo top remains at y=389 instead of changing from y=379 to y=389. |
| More → Memories | Re-recorded during this audit; no late vertical correction. |
| More → Privacy → More | Push and back recording; header and content remain aligned. |
| More → Licenses → license detail → Licenses → More | Recorded both navigation levels and returns; no late correction. All license entries share the same detail view. |
| More → Photo Sources → More | Sheet and dismissal recorded; bar and source content settle together. |
| Photo Sources → folder picker → Photo Sources | Opened the system picker and cancelled with Escape; no folder selected. |
| More → Duplicates → More | Presented and dismissed the scan invitation; no scan/deletion started in this follow-up. Loaded duplicate rows remain covered by renderer tests. |
| Memories → slideshow → Memories | Recorded image loading, cover and dismissal; controls stay fixed after presentation. |
| Memories → photo viewer → Memories | Recorded cover, loaded photo and dismissal. |
| Photo viewer → Around this time → photo viewer | Recorded nested sheet with a loaded nearby-photo grid and dismissed it. |
| Search results and recent search | Re-ran Mountains with OCR and visual results, scrolled and changed the media filter. Search uses one persistent navigation root throughout. |
| Search → OCR/photo viewer → results | Recorded cover/dismissal with text and photo content. |
| Photo viewer → Find similar | Returned 50 similar items within the existing viewer; controls retain their position as the result set changes. |
| Photo viewer → Share → photo viewer | Opened and cancelled the platform share sheet; no destination selected. |
| Video result → system player → results | Opened the filtered video result and dismissed with Escape. The fixture is a screen recording, so app-like controls inside the video are recorded content. The initial unfiltered tap hit the dock and is excluded from video coverage. |
| Search ↔ More | Switched both ways during the routes above; no late bar correction. |
| Onboarding | Opened all three pages using a process-only onboarding argument on the test simulator. Reviewed both page transitions; did not start indexing. |
| Upgrade | Used an actual Release build without Pro on the test simulator. Presented and closed Upgrade from the Pro card and from gated Duplicates. No purchase or restore attempted. |
| Launch/preparation → Search | Cold-launch recording from the preceding fix; both use the shared Search navigation treatment. |

The main route recordings use the Memorable Debug scheme on `Memorable Release 2K`, containing 2,010 photos and one video. Onboarding and free-tier Upgrade checks use the separate `iPhone 17 Pro` test simulator. The simulator profile was restored to Memorable Debug afterward.

## Verification limits

- No remaining instance of the reported navigation-bar jump was observed in these recordings.
- Initial/resumed/incremental indexing and recovery branches were traced under the same Search root, and their existing state/renderer tests passed. This audit did not rebuild the seeded library or force every thermal, permission, memory-pressure, empty-library or failure state live.
- Unsupported-device and permission/error screens do not own a navigation stack or push a titled destination. Reviewed their code; did not manufacture those device/error states.
- No physical-device or older-iOS navigation run was performed. Accessibility renderer tests passed, but the complete navigation matrix was not repeated at accessibility text sizes. These remain release-checklist requirements.
- Full Debug simulator suite: **950 passed, 0 failed, 1 skipped**. The skip is the opt-in dataset mutation harness. Debug and Release app builds succeeded; test build reported no warnings. `git diff --check` passed.
- The complete pre-merge wrapper's simulator-launch issue from the prior fix remains unresolved. It was not rerun for these test/documentation-only additions; this report does not claim a passing complete release or pre-merge gate.

Compact clips and transition frame sheets are saved in the current task's `memory-navigation-audit` artifact directory. The earlier Search-to-Memories before/after evidence remains in `memory-opening-fix`. Raw temporary recordings and redundant test-product copies are removed after verification; Xcode logs and result bundles are retained.
