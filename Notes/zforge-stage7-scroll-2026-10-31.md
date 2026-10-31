# Zforge stage 7 — scroll (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Zforge `7ea66ec`
(clean), same build as the earlier stages (`Zforge.debug.dylib` `da557f4a8d41b160`). Zforge repository
only read. Real runs announced before and after.

## Test and new capability

`testColumnPreviewRefitsAfterUserScrollsLeft`: `XCUIElement.scroll(byDeltaX:deltaY:)` on the Columns
view's horizontal SwiftUI scroll view, followed by layout checks.

## What real scrolls look like (screen guard, real run)

XCTest sends one record per scroll (`eventType` 5, `deltaVector`, `duration` 0.08 s for 400 pt).
testmanagerd turns `scroll(byDeltaX: 400)` into 19 continuous (trackpad-like) pixel scroll events of
21–22 pt (sum exactly 400 on axis 2), without scroll or momentum phases. The screen guard now logs
these fields for synthetic scroll events.

## Tool changes

The agent's scroll was a single pixel wheel event and had no effect. Fixes:
- deltas are sent as continuous pixel events of ~21 pt spread over the record's duration (spreading
  them over 15 ms, as the guard timestamps suggested, worked only intermittently — with a debugger
  attached, i.e. slower processing, it passed);
- the CGEvent's window number goes in field 51 (what `+[NSEvent eventWithCGEvent:]` reads; found
  empirically) and the window-relative location is set with the private
  `CGEventSetWindowLocation` — without them the event had no window (`windowNumber` 0, location −1,721)
  and AppKit did not route it to the scroll view;
- the CGEvent carries the app's pid so the stage-4 isolation filter keeps it.

## Sample app

New test `testHorizontalScroll` (SwiftUI horizontal `ScrollView` reporting its offset; scroll forward
then back) and compile-time regression `SCROLL` (`.scrollDisabled`).

| | Real | Simulated | Tree |
|---|---|---|---|
| base | pass 7.61 s | pass 8.15 s | identical (34) |
| SCROLL | fail line 112 | fail line 112 | 44 vs 43, polling after the failure only |

## Zforge results

| | Real | Simulated | Assertion | Tree |
|---|---|---|---|---|
| unmodified | pass 19.35 s | pass 19.45–19.94 s (3 runs) | — | identical (119) |
| noscroll: the columns `ScrollView` has no axes, `0dd9c8648dba5a93` | fail `ZforgeUITests.swift:791` 382 ≤ 392 | same values | same | identical (102) |

## Revalidation (simulated, no screen)

Sample suite and its regressions, the menu-hover and scroll sample tests and their regressions, and all
12 validated Zforge tests (plus the compact toolbar test alone): same outcomes; trees identical except
`Terminate` steps from run composition, one asynchronous runtime note, and post-failure polling.

## Verdict

**Equivalent** after the scroll fixes (outcome, identical tree, regression with the same values).
