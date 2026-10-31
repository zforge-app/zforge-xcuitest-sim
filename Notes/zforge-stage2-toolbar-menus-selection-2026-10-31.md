# Zforge stage 2 — toolbar menus and modifier-click selection (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Tool `2077368`
(unchanged during this stage). Zforge `7ea66ec` (clean), same build as the earlier comparisons
(`Zforge.debug.dylib` `da557f4a8d41b160`; simulated copy: same `__text`). Zforge repository only read.
Real runs announced before and after.

## Tests and new capabilities

| Test | New capabilities |
|---|---|
| `testCompactToolbarMenusOpenFromTheirToolbarButtons` | menu opened from a toolbar button (overflow), AX value tracking the menu's presentation, compact view-mode pop-up menu |
| `testFileOpenPrecedesOpenWithAndTracksSelectionInListMode` | ⌘-click multi-selection in a list, File menu contents following the selection, full-screen `app.screenshot()` |

## Results

| Test | Real | Simulated | Activity tree |
|---|---|---|---|
| testCompactToolbarMenusOpenFromTheirToolbarButtons | pass 17.28 s | pass 18.53 s | identical (106) |
| testFileOpenPrecedesOpenWithAndTracksSelectionInListMode | pass 30.13 s | pass 36.94 s | identical (317) |

| Regression (only the affected test) | Real | Simulated | Same assertion |
|---|---|---|---|
| overflow: compact overflow button no longer tracks its menu (`tracksOverflowPresentation: false`), `df75a90f4208f327` | fail `ZforgeUITests.swift:911` "Collapsed" ≠ "Expanded" | same | yes; trees equal up to async debug-description order |
| cmdclick: ⌘-click clears the selection, `553d11bb98db41fd` | fail `:248` "Multiple selection: list" | same | yes; same |

Screen guard: real 2–4 frontmost changes and 126–754 synthetic events per run; simulated 0 synthetic
events. In the first simulated run the frontmost app changed twice because testmanagerd asked for
Automation Mode authentication (coreautha, ~2 s; `Test session ... requesting automation mode`) after
~20 min without UI tests — inherent to XCUITest on this Mac, see the feasibility note. During the
real overflow-regression run the user produced 53 hardware events; the outcome matched anyway.

## Verdict

Both tests: **equivalent** (outcome, identical trees, regressions caught on the same assertions).
Simulated is 7 % and 23 % slower.
